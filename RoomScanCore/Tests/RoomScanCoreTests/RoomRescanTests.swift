import Foundation
import XCTest
@testable import RoomScanCore

/// These contracts are authored on the Windows host but cannot be executed
/// here because no Swift toolchain or Apple SDK is installed.
final class RoomRescanTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    func testFixtureProposalPreservesBaseIDsAndUsesCandidateGeometry() throws {
        let base = try makeBasePayload()
        let candidate = try makeCandidateSnapshot()
        let proposal = try makeProposal(base: base, candidate: candidate)

        XCTAssertEqual(
            proposal.resultPayload.semanticSnapshot.structuralElements.map(\.id),
            base.semanticSnapshot.structuralElements.map(\.id)
        )
        XCTAssertEqual(
            proposal.resultPayload.semanticSnapshot.objectElements.map(\.id),
            base.semanticSnapshot.objectElements.map(\.id)
        )
        XCTAssertEqual(
            proposal.resultPayload.semanticSnapshot.structuralElements.first?.dimensionsMeters,
            candidate.structuralElements.first?.dimensionsMeters
        )
        XCTAssertEqual(
            proposal.resultPayload.semanticSnapshot.objectElements.first?.label,
            candidate.objectElements.first?.label
        )
        XCTAssertEqual(
            proposal.resultPayload.semanticSnapshot.objectElements.first?.origin,
            .deterministicFixture
        )
        XCTAssertEqual(
            proposal.resultPayload.semanticSnapshot.objectElements.first?.provenance,
            candidate.objectElements.first?.provenance
        )
        XCTAssertEqual(proposal.resultPayload.annotations, base.annotations)
        XCTAssertEqual(proposal.resultPayload.measurements, base.measurements)
        XCTAssertEqual(proposal.resultPayload.photos, base.photos)
        XCTAssertTrue(proposal.preview.measurementsRemainUnrevalidated)
        XCTAssertTrue(proposal.preview.changes.contains { $0.kind == .dimensions })
        XCTAssertTrue(proposal.preview.changes.contains { $0.kind == .label })
        XCTAssertTrue(proposal.preview.changes.contains { $0.kind == .semanticClassification })
    }

    func testProposalDigestIsDeterministicAcrossMatchInputOrder() throws {
        let base = try makeBasePayload()
        let candidate = try makeCandidateSnapshot()
        let matches = try makeMatches()

        let forward = try RoomRescanEngine.makeFixtureProposal(
            basePayload: base,
            expectedHeadRevisionID: "revision-001",
            registrationProof: registrationProof(),
            candidateSnapshot: candidate,
            matches: matches
        )
        let reverse = try RoomRescanEngine.makeFixtureProposal(
            basePayload: base,
            expectedHeadRevisionID: "revision-001",
            registrationProof: registrationProof(),
            candidateSnapshot: candidate,
            matches: Array(matches.reversed())
        )

        XCTAssertEqual(forward.digest, reverse.digest)
        XCTAssertEqual(forward, reverse)
    }

    func testProposalDigestIsDeterministicAcrossCandidateArrayOrder() throws {
        let base = try makeBasePayload()
        let candidate = try makeCandidateSnapshot()
        var reordered = candidate
        reordered.structuralElements.reverse()

        let forward = try makeProposal(base: base, candidate: candidate)
        let reverse = try makeProposal(base: base, candidate: reordered)

        XCTAssertEqual(forward.digest, reverse.digest)
        XCTAssertEqual(forward.candidateSnapshot, reverse.candidateSnapshot)
    }

    func testProposalDigestIsDeterministicAcrossBaseArrayOrder() throws {
        let base = try makeBasePayload()
        let candidate = try makeCandidateSnapshot()
        var reorderedBase = base
        reorderedBase.semanticSnapshot.structuralElements.reverse()

        let forward = try makeProposal(base: base, candidate: candidate)
        let reverse = try makeProposal(base: reorderedBase, candidate: candidate)

        XCTAssertEqual(forward.digest, reverse.digest)
        XCTAssertEqual(forward.resultPayload.semanticSnapshot, reverse.resultPayload.semanticSnapshot)
    }

    func testEngineRejectsUnprovenWrongFixtureAndWrongFrame() throws {
        let base = try makeBasePayload()
        let candidate = try makeCandidateSnapshot()

        var unproven = registrationProof()
        unproven.proofToken = "not-proven"
        assertRescanError(.unprovenRegistration) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: unproven,
                candidateSnapshot: candidate,
                matches: try makeMatches()
            )
        }

        var wrongFixture = registrationProof()
        wrongFixture.fixtureID = "other-fixture"
        assertRescanError(.wrongFixture) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: wrongFixture,
                candidateSnapshot: candidate,
                matches: try makeMatches()
            )
        }

        var wrongFrame = registrationProof()
        wrongFrame.coordinateFrameID = "other-frame"
        assertRescanError(.wrongCoordinateFrame) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: wrongFrame,
                candidateSnapshot: candidate,
                matches: try makeMatches()
            )
        }
    }

    func testEngineRejectsMissingExtraDuplicateAndLayerOrKindMismatchedMatches() throws {
        let base = try makeBasePayload()
        let candidate = try makeCandidateSnapshot()
        let matches = try makeMatches()

        assertRescanError(.incompleteBijection) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: candidate,
                matches: Array(matches.dropLast())
            )
        }

        var duplicateBase = matches
        duplicateBase[1].baseElementID = duplicateBase[0].baseElementID
        assertRescanError(.duplicateMatch) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: candidate,
                matches: duplicateBase
            )
        }

        var duplicateCandidate = matches
        duplicateCandidate[1].candidateElementID = duplicateCandidate[0].candidateElementID
        assertRescanError(.duplicateMatch) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: candidate,
                matches: duplicateCandidate
            )
        }

        var wrongLayer = matches
        wrongLayer[0].candidateLayer = .object
        assertRescanError(.layerMismatch) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: candidate,
                matches: wrongLayer
            )
        }

        var wrongKind = matches
        wrongKind[0].candidateKind = "not-floor"
        assertRescanError(.kindMismatch) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: candidate,
                matches: wrongKind
            )
        }

        var changedCategory = candidate
        changedCategory.objectElements[0].kind = "table"
        var categoryMatch = matches
        categoryMatch[2].candidateKind = "table"
        assertRescanError(.kindMismatch) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: changedCategory,
                matches: categoryMatch
            )
        }

        var extraCandidate = candidate
        extraCandidate.objectElements.append(
            try semanticElement(
                id: "candidate-extra-001",
                kind: "lamp",
                label: "Extra lamp",
                dimensions: RoomDimensions(width: 0.4, height: 1.2, depth: 0.4),
                origin: .deterministicFixture
            )
        )
        assertRescanError(.incompleteBijection) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: extraCandidate,
                matches: matches
            )
        }
    }

    func testEngineRejectsInvalidCandidateGeometryAndTamperedProposal() throws {
        let base = try makeBasePayload()
        var candidate = try makeCandidateSnapshot()
        candidate.objectElements[0].dimensionsMeters.width = .infinity
        assertRescanError(.invalidCandidateGeometry) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: candidate,
                matches: try makeMatches()
            )
        }

        let validCandidate = try makeCandidateSnapshot()
        var proposal = try makeProposal(base: base, candidate: validCandidate)
        proposal.resultPayload.semanticSnapshot.objectElements[0].label = "Tampered"
        assertRescanError(.tamperedProposal) {
            _ = try RoomRescanEngine.verifyFixtureProposal(proposal, against: base)
        }

        var duplicateSource = validCandidate
        let duplicateSourceIdentifier =
            duplicateSource.structuralElements[0].provenance?.sourceIdentifier ?? "duplicate"
        duplicateSource.structuralElements[1].provenance?.sourceIdentifier =
            duplicateSourceIdentifier
        assertRescanError(.invalidCandidateGeometry) {
            _ = try RoomRescanEngine.makeFixtureProposal(
                basePayload: base,
                expectedHeadRevisionID: "revision-001",
                registrationProof: registrationProof(),
                candidateSnapshot: duplicateSource,
                matches: try makeMatches()
            )
        }
    }

    func testEngineRejectsZeroSingularAndNonAffineCandidateTransforms() throws {
        let base = try makeBasePayload()
        let candidate = try makeCandidateSnapshot()

        var zeroTransform = candidate
        zeroTransform.objectElements[0].transform = RoomTransform4x4(
            columnMajorValues: Array(repeating: 0, count: 16)
        )
        assertRescanError(.invalidCandidateGeometry) {
            _ = try makeProposal(base: base, candidate: zeroTransform)
        }

        var singularTransform = candidate
        var singularValues = try XCTUnwrap(singularTransform.objectElements[0].transform).columnMajorValues
        singularValues[0] = 0
        singularTransform.objectElements[0].transform = RoomTransform4x4(
            columnMajorValues: singularValues
        )
        assertRescanError(.invalidCandidateGeometry) {
            _ = try makeProposal(base: base, candidate: singularTransform)
        }

        var nonAffineTransform = candidate
        var nonAffineValues = try XCTUnwrap(nonAffineTransform.objectElements[0].transform).columnMajorValues
        nonAffineValues[3] = 0.25
        nonAffineTransform.objectElements[0].transform = RoomTransform4x4(
            columnMajorValues: nonAffineValues
        )
        assertRescanError(.invalidCandidateGeometry) {
            _ = try makeProposal(base: base, candidate: nonAffineTransform)
        }
    }

    func testGenericAppendRejectsRescanReason() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let saved = try await store.saveDraft(try makeDraft(), decision: .save)
        let summary = try XCTUnwrap(saved)
        let package = try await store.load(projectID: summary.projectID)
        let payload = try XCTUnwrap(package.revisions.last).payload

        await assertStoreError(.invalidRevisionReason(reason: .rescan, restoredFromRevisionID: nil)) {
            _ = try await store.appendRevision(
                projectID: summary.projectID,
                revisionID: "revision-002",
                parentRevisionID: summary.headRevisionID,
                reason: .rescan,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }
    }

    func testAcceptFixtureRescanCreatesOneImmutableChildAndPreservesParentBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photoSource = root.deletingLastPathComponent().appendingPathComponent("rescan-source-photo.jpg")
        defer { try? FileManager.default.removeItem(at: photoSource) }
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: photoSource)

        let store = makeStore(root: root, revisionIDs: ["revision-001", "revision-002", "revision-003"])
        let saved = try await store.saveDraft(
            try makeDraft(withPhotoSource: photoSource),
            decision: .save,
            assets: [
                RoomAssetInput(
                    sourceURL: photoSource,
                    destination: try RoomRelativePath("photos/reference.jpg"),
                    scope: .revision
                )
            ]
        )
        let summary = try XCTUnwrap(saved)
        let parentURL = revisionURL(root: root, projectID: summary.projectID, revisionID: "revision-001")
        let parentBytes = try byteSnapshot(at: parentURL)
        let package = try await store.load(projectID: summary.projectID)
        let base = try XCTUnwrap(package.revisions.last).payload
        let proposal = try makeProposal(base: base, candidate: try makeCandidateSnapshot(projectID: summary.projectID))

        let accepted = try await store.acceptFixtureRescan(
            projectID: summary.projectID,
            expectedHeadRevisionID: "revision-001",
            proposal: proposal,
            newRevisionID: "revision-002"
        )
        let reloaded = try await store.load(projectID: summary.projectID)

        XCTAssertEqual(accepted.reason, .rescan)
        XCTAssertEqual(accepted.parentRevisionID, "revision-001")
        XCTAssertEqual(accepted.captureEvidence?.source, .deterministicFixture)
        XCTAssertTrue(accepted.captureEvidence?.artifacts.allSatisfy { $0.status != .present } ?? false)
        XCTAssertNil(accepted.captureEvidence?.captureAttemptID)
        XCTAssertNil(accepted.captureEvidence?.coordinateSpaceEpochID)
        XCTAssertEqual(reloaded.manifest.revisionIDs, ["revision-001", "revision-002"])
        XCTAssertEqual(reloaded.manifest.headRevisionID, "revision-002")
        XCTAssertEqual(try byteSnapshot(at: parentURL), parentBytes)
        let childPhoto = revisionURL(root: root, projectID: summary.projectID, revisionID: "revision-002")
            .appendingPathComponent("photos/reference.jpg")
        XCTAssertEqual(try Data(contentsOf: childPhoto), try Data(contentsOf: photoSource))

        let reverted = try await store.restoreAsNewRevision(
            projectID: summary.projectID,
            sourceRevisionID: "revision-001",
            newRevisionID: "revision-003"
        )
        let afterRevert = try await store.load(projectID: summary.projectID)
        XCTAssertEqual(reverted.reason, .revert)
        XCTAssertEqual(reverted.parentRevisionID, "revision-002")
        XCTAssertEqual(afterRevert.manifest.revisionIDs, ["revision-001", "revision-002", "revision-003"])
    }

    func testPreviewAndUndoCauseNoStoreMutationAndAcceptRejectsStaleDoubleAndTamperedInput() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, revisionIDs: ["revision-001", "revision-002", "revision-003"])
        let saved = try await store.saveDraft(try makeDraft(), decision: .save)
        let summary = try XCTUnwrap(saved)
        let before = try await store.load(projectID: summary.projectID)
        let proposal = try makeProposal(
            base: try XCTUnwrap(before.revisions.last).payload,
            candidate: try makeCandidateSnapshot(projectID: summary.projectID)
        )

        // Preview / undo are intentionally pure proposal operations: no store
        // method is invoked and therefore no revision ID is allocated.
        _ = proposal.preview
        let afterPreview = try await store.load(projectID: summary.projectID)
        XCTAssertEqual(afterPreview, before)

        var tampered = proposal
        tampered.digest = "0" + proposal.digest.dropFirst()
        let tamperedProposal = tampered
        await assertStoreError(.invalidRescanProposal("The rescan proposal digest does not match its deterministic inputs.")) {
            _ = try await store.acceptFixtureRescan(
                projectID: summary.projectID,
                expectedHeadRevisionID: "revision-001",
                proposal: tamperedProposal,
                newRevisionID: "revision-002"
            )
        }
        let afterTamper = try await store.load(projectID: summary.projectID)
        XCTAssertEqual(afterTamper, before)

        _ = try await store.acceptFixtureRescan(
            projectID: summary.projectID,
            expectedHeadRevisionID: "revision-001",
            proposal: proposal,
            newRevisionID: "revision-002"
        )
        await assertStoreError(
            .parentDoesNotMatchHead(
                projectID: summary.projectID,
                expected: "revision-002",
                actual: "revision-001"
            )
        ) {
            _ = try await store.acceptFixtureRescan(
                projectID: summary.projectID,
                expectedHeadRevisionID: "revision-001",
                proposal: proposal,
                newRevisionID: "revision-003"
            )
        }
    }

    func testFixtureRescanFaultRollsBackAndRetryWithSameIDSucceeds() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let failingStore = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001", "revision-002"]
            ),
            faultInjector: FailingRoomProjectStoreFaultInjector(
                point: .afterRevisionPromotionBeforeManifest
            )
        )
        let saved = try await failingStore.saveDraft(try makeDraft(), decision: .save)
        let summary = try XCTUnwrap(saved)
        let base = try await failingStore.load(projectID: summary.projectID)
        let proposal = try makeProposal(
            base: try XCTUnwrap(base.revisions.last).payload,
            candidate: try makeCandidateSnapshot(projectID: summary.projectID)
        )

        await assertStoreError(.injectedFailure(.afterRevisionPromotionBeforeManifest)) {
            _ = try await failingStore.acceptFixtureRescan(
                projectID: summary.projectID,
                expectedHeadRevisionID: "revision-001",
                proposal: proposal,
                newRevisionID: "revision-002"
            )
        }
        let afterFailure = try await failingStore.load(projectID: summary.projectID)
        XCTAssertEqual(afterFailure.manifest.revisionIDs, ["revision-001"])

        let retryStore = makeStore(root: root, revisionIDs: ["revision-002"])
        let retry = try await retryStore.acceptFixtureRescan(
            projectID: summary.projectID,
            expectedHeadRevisionID: "revision-001",
            proposal: proposal,
            newRevisionID: "revision-002"
        )
        XCTAssertEqual(retry.revisionID, "revision-002")
    }

    private func makeProposal(
        base: RoomRevisionPayload,
        candidate: RoomSemanticSnapshot
    ) throws -> RoomFixtureRescanProposal {
        try RoomRescanEngine.makeFixtureProposal(
            basePayload: base,
            expectedHeadRevisionID: base.semanticSnapshot.revisionID,
            registrationProof: registrationProof(projectID: base.semanticSnapshot.projectID),
            candidateSnapshot: candidate,
            matches: try makeMatches()
        )
    }

    private func registrationProof(
        projectID: String = "project-001"
    ) -> RoomDeterministicRescanRegistrationProof {
        RoomDeterministicRescanRegistrationProof(
            fixtureID: RoomDeterministicRescanRegistrationProof.fixtureV1ID,
            projectID: projectID,
            baseRevisionID: "revision-001",
            coordinateFrameID: RoomDeterministicRescanRegistrationProof.fixtureV1FrameID,
            proofToken: RoomDeterministicRescanRegistrationProof.fixtureV1ProofToken
        )
    }

    private func makeMatches() throws -> [RoomRescanElementMatch] {
        [
            RoomRescanElementMatch(
                baseElementID: "structure-floor-001",
                candidateElementID: "candidate-floor-001",
                baseLayer: .structural,
                candidateLayer: .structural,
                baseKind: "floor",
                candidateKind: "floor"
            ),
            RoomRescanElementMatch(
                baseElementID: "structure-wall-001",
                candidateElementID: "candidate-wall-001",
                baseLayer: .structural,
                candidateLayer: .structural,
                baseKind: "wall",
                candidateKind: "wall"
            ),
            RoomRescanElementMatch(
                baseElementID: "object-desk-001",
                candidateElementID: "candidate-desk-001",
                baseLayer: .object,
                candidateLayer: .object,
                baseKind: "desk",
                candidateKind: "desk"
            ),
        ]
    }

    private func makeBasePayload() throws -> RoomRevisionPayload {
        RoomRevisionPayload(
            semanticSnapshot: RoomSemanticSnapshot(
                projectID: "project-001",
                revisionID: "revision-001",
                units: "meters",
                accuracyDisclaimer: "Measurements are estimates and are not survey-grade measurements.",
                structuralElements: [
                    try semanticElement(
                        id: "structure-floor-001",
                        kind: "floor",
                        label: "Floor",
                        dimensions: RoomDimensions(width: 4, height: 0, depth: 3),
                        origin: .legacyUnknown
                    ),
                    try semanticElement(
                        id: "structure-wall-001",
                        kind: "wall",
                        label: "North wall",
                        dimensions: RoomDimensions(width: 4, height: 2.7, depth: 0),
                        origin: .legacyUnknown
                    ),
                ],
                objectElements: [
                    try semanticElement(
                        id: "object-desk-001",
                        kind: "desk",
                        label: "Desk",
                        dimensions: RoomDimensions(width: 1.2, height: 0.75, depth: 0.6),
                        origin: .legacyUnknown
                    ),
                ]
            ),
            annotations: [RoomAnnotation(id: "annotation-001", createdAt: date, text: "Leave clear")],
            measurements: [RoomMeasurement(id: "measurement-001", label: "Width", valueMeters: 4)],
            photos: []
        )
    }

    private func makeCandidateSnapshot(
        projectID: String = "project-001"
    ) throws -> RoomSemanticSnapshot {
        RoomSemanticSnapshot(
            projectID: projectID,
            revisionID: "candidate-revision-v1",
            units: "meters",
            accuracyDisclaimer: "Simulated candidate values remain estimates and are not survey-grade measurements.",
            structuralElements: [
                try semanticElement(
                    id: "candidate-floor-001",
                    kind: "floor",
                    label: "Floor, recaptured",
                    dimensions: RoomDimensions(width: 4.05, height: 0, depth: 3),
                    origin: .deterministicFixture,
                    transformOffset: 0.05,
                    confidence: .medium,
                    source: "candidate-surface-floor-001"
                ),
                try semanticElement(
                    id: "candidate-wall-001",
                    kind: "wall",
                    label: "North wall, recaptured",
                    dimensions: RoomDimensions(width: 4.1, height: 2.7, depth: 0),
                    origin: .deterministicFixture,
                    transformOffset: 0.1,
                    confidence: .medium,
                    source: "candidate-surface-wall-001"
                ),
            ],
            objectElements: [
                try semanticElement(
                    id: "candidate-desk-001",
                    kind: "desk",
                    label: "Work table",
                    dimensions: RoomDimensions(width: 1.3, height: 0.75, depth: 0.65),
                    origin: .deterministicFixture,
                    transformOffset: 0.2,
                    confidence: .low,
                    source: "candidate-object-desk-001"
                ),
            ]
        )
    }

    private func semanticElement(
        id: String,
        kind: String,
        label: String,
        dimensions: RoomDimensions,
        origin: RoomElementOrigin,
        transformOffset: Double = 0,
        confidence: RoomClassificationConfidence = .unknown,
        source: String? = nil
    ) throws -> RoomSemanticElement {
        let sourceIdentifier = source ?? "source-\(id)"
        return RoomSemanticElement(
            id: id,
            kind: kind,
            label: label,
            dimensionsMeters: dimensions,
            transform: RoomTransform4x4(columnMajorValues: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                transformOffset, 0, 0, 1,
            ]),
            polygonCorners: [
                RoomPoint3D(x: 0, y: 0, z: 0),
                RoomPoint3D(x: 1, y: 0, z: 0),
            ],
            provenance: RoomElementProvenance(
                framework: "deterministic-fixture",
                sourceIdentifier: sourceIdentifier,
                classificationConfidence: confidence,
                flattenedAttributeIdentifiers: ["fixture-attribute"],
                captureAttemptID: nil,
                coordinateSpaceEpochID: nil
            ),
            mobility: origin == .legacyUnknown ? .unknown : .fixed,
            origin: origin
        )
    }

    private func makeDraft(withPhotoSource source: URL? = nil) throws -> RoomDraft {
        var payload = try makeBasePayload()
        if source != nil {
            payload.photos = [
                RoomPhoto(
                    id: "photo-001",
                    createdAt: date,
                    assetRelativePath: try RoomRelativePath("photos/reference.jpg"),
                    caption: "Reference"
                ),
            ]
        }
        return RoomDraft(
            metadata: RoomMetadata(
                projectID: "draft",
                customName: "Rescan base",
                captureDate: date,
                lastRevisedDate: date,
                manualLocation: "Fixture lab",
                optionalGPS: nil,
                notes: "",
                tags: ["fixture"],
                thumbnailRelativePath: nil,
                archived: false
            ),
            revision: payload
        )
    }

    private func makeStore(
        root: URL,
        revisionIDs: [String] = ["revision-001"]
    ) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: revisionIDs
            )
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomRescanTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func revisionURL(root: URL, projectID: String, revisionID: String) -> URL {
        root
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revisionID, isDirectory: true)
    }

    private func byteSnapshot(at directory: URL) throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var bytes: [String: Data] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            bytes[relative] = try Data(contentsOf: url)
        }
        return bytes
    }

    private func assertRescanError(
        _ expected: RoomRescanError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("Expected \(expected) to be thrown.")
        } catch {
            XCTAssertEqual(error as? RoomRescanError, expected)
        }
    }

    private func assertStoreError(
        _ expected: RoomProjectStoreError,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected) to be thrown.")
        } catch {
            XCTAssertEqual(error as? RoomProjectStoreError, expected)
        }
    }
}
