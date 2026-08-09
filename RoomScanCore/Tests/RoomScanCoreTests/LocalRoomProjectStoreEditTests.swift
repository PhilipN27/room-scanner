import Foundation
import XCTest
@testable import RoomScanCore

final class LocalRoomProjectStoreEditTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    func testCommitEditRevisionCarriesParentAssetsAndEvidenceWithoutMutatingParent() async throws {
        let root = temporaryRoot()
        let source = root.deletingLastPathComponent().appendingPathComponent("RoomEditSources-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let prepared = try makeEvidenceBackedDraft(sourceDirectory: source)
        let store = makeStore(root: root, revisions: ["revision-001", "revision-002"])

        let initial = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(
                draft: prepared.draft,
                evidence: prepared.evidence,
                assets: prepared.assets
            ),
            decision: .save
        )
        let saved = try XCTUnwrap(initial)
        let parentURL = revisionURL(root: root, projectID: saved.projectID, revisionID: "revision-001")
        let parentBytes = try byteSnapshot(at: parentURL)
        let package = try await store.load(projectID: saved.projectID)
        var editedPayload = try XCTUnwrap(package.revisions.last).payload
        editedPayload.semanticSnapshot.objectElements[0].label = "Edited desk"

        let committed = try await store.commitEditRevision(
            projectID: saved.projectID,
            expectedHeadRevisionID: "revision-001",
            payload: editedPayload,
            newRevisionID: "revision-002"
        )
        let editURL = revisionURL(root: root, projectID: saved.projectID, revisionID: "revision-002")
        let reloaded = try await store.load(projectID: saved.projectID)

        XCTAssertEqual(committed.reason, .edit)
        XCTAssertEqual(committed.parentRevisionID, "revision-001")
        XCTAssertEqual(reloaded.manifest.headRevisionID, "revision-002")
        XCTAssertEqual(try byteSnapshot(at: parentURL), parentBytes)
        XCTAssertEqual(
            try Data(contentsOf: editURL.appendingPathComponent("photos/reference-001.jpg")),
            prepared.photoBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: editURL.appendingPathComponent("attachments/future.bin")),
            prepared.attachmentBytes
        )
        for artifact in prepared.presentArtifacts {
            XCTAssertEqual(
                try Data(contentsOf: editURL.appendingPathComponent(artifact.path)),
                artifact.data
            )
        }
        XCTAssertEqual(
            reloaded.revisions.last?.manifest.captureEvidence,
            prepared.evidence
        )
    }

    func testCommitEditRevisionRejectsStaleHeadWithoutHistoryMutation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, revisions: ["revision-001", "revision-002"])
        let saveResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(saveResult)
        let package = try await store.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(package.revisions.last).payload
        let parentURL = revisionURL(root: root, projectID: saved.projectID, revisionID: "revision-001")
        let parentBytes = try byteSnapshot(at: parentURL)

        do {
            _ = try await store.commitEditRevision(
                projectID: saved.projectID,
                expectedHeadRevisionID: "revision-stale",
                payload: payload,
                newRevisionID: "revision-002"
            )
            XCTFail("Expected a stale optimistic edit to fail.")
        } catch let error as RoomProjectStoreError {
            guard case .parentDoesNotMatchHead = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }

        let reloaded = try await store.load(projectID: saved.projectID)
        XCTAssertEqual(reloaded.manifest.revisionIDs, ["revision-001"])
        XCTAssertEqual(try byteSnapshot(at: parentURL), parentBytes)
    }

    func testCommitEditFailureRollsBackAndSameRevisionIDCanRetry() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialStore = makeStore(root: root, revisions: ["revision-001", "revision-002"])
        let saveResult = try await initialStore.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(saveResult)
        let package = try await initialStore.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(package.revisions.last).payload
        let parentURL = revisionURL(root: root, projectID: saved.projectID, revisionID: "revision-001")
        let parentBytes = try byteSnapshot(at: parentURL)

        let failingStore = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: [],
                revisionIDs: ["revision-002"]
            ),
            faultInjector: FailingRoomProjectStoreFaultInjector(
                point: .afterRevisionPromotionBeforeManifest
            )
        )
        do {
            _ = try await failingStore.commitEditRevision(
                projectID: saved.projectID,
                expectedHeadRevisionID: "revision-001",
                payload: payload,
                newRevisionID: "revision-002"
            )
            XCTFail("Expected injected edit promotion failure.")
        } catch let error as RoomProjectStoreError {
            XCTAssertEqual(error, .injectedFailure(.afterRevisionPromotionBeforeManifest))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: revisionURL(root: root, projectID: saved.projectID, revisionID: "revision-002").path))
        XCTAssertEqual(try byteSnapshot(at: parentURL), parentBytes)

        let retryStore = makeStore(root: root, revisions: ["revision-002"])
        let retry = try await retryStore.commitEditRevision(
            projectID: saved.projectID,
            expectedHeadRevisionID: "revision-001",
            payload: payload,
            newRevisionID: "revision-002"
        )
        XCTAssertEqual(retry.revisionID, "revision-002")
    }

    func testSpatialValidationRejectsDanglingAnnotation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var draft = makeDraft()
        draft.revision.annotations = [
            RoomAnnotation(
                id: "note-001",
                createdAt: date,
                text: "Dangling",
                point: RoomPoint3D(x: 0, y: 0, z: 0),
                attachedElementID: "missing-element"
            )
        ]
        do {
            _ = try await store.saveDraft(draft, decision: .save)
            XCTFail("Expected dangling annotation to be rejected.")
        } catch let error as RoomProjectStoreError {
            guard case .invalidSpatialValue = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }
    }

    func testSpatialValidationRejectsUnpairedMeasurementEndpoints() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var draft = makeDraft()
        draft.revision.measurements = [
            RoomMeasurement(
                id: "measure-001",
                label: "Unpaired",
                valueMeters: 1,
                startPoint: RoomPoint3D(x: 0, y: 0, z: 0),
                endPoint: nil
            )
        ]

        do {
            _ = try await store.saveDraft(draft, decision: .save)
            XCTFail("Expected unpaired measurement endpoints to be rejected.")
        } catch let error as RoomProjectStoreError {
            guard case .invalidSpatialValue = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }
    }

    func testSpatialValidationRejectsMismatchedAnchoredMeasurementValue() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var draft = makeDraft()
        draft.revision.measurements = [
            RoomMeasurement(
                id: "measure-001",
                label: "Mismatched",
                valueMeters: 3,
                startPoint: RoomPoint3D(x: 0, y: 0, z: 0),
                endPoint: RoomPoint3D(x: 0, y: 4, z: 0)
            )
        ]

        do {
            _ = try await store.saveDraft(draft, decision: .save)
            XCTFail("Expected mismatched anchored measurement to be rejected.")
        } catch let error as RoomProjectStoreError {
            guard case .invalidSpatialValue = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }
    }

    private func makeStore(root: URL, revisions: [String] = ["revision-001"]) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: revisions
            )
        )
    }

    private func makeDraft() -> RoomDraft {
        RoomDraft(
            metadata: RoomMetadata(
                projectID: "draft-project",
                customName: "Editable room",
                captureDate: date,
                lastRevisedDate: date,
                manualLocation: "Studio",
                optionalGPS: nil,
                notes: "",
                tags: [],
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
                            provenance: roomPlanProvenance(),
                            mobility: .structural,
                            origin: .roomPlan
                        )
                    ],
                    objectElements: [
                        RoomSemanticElement(
                            id: "object-001",
                            kind: "desk",
                            label: "Desk",
                            dimensionsMeters: RoomDimensions(width: 1, height: 1, depth: 1),
                            transform: identityTransform(),
                            provenance: roomPlanProvenance(sourceID: "object-source-001"),
                            mobility: .fixed,
                            origin: .roomPlan
                        )
                    ]
                ),
                annotations: [],
                measurements: [],
                photos: []
            )
        )
    }

    private func makeEvidenceBackedDraft(sourceDirectory: URL) throws -> EvidenceBackedDraft {
        var draft = makeDraft()
        draft.revision.photos = [
            RoomPhoto(
                id: "photo-001",
                createdAt: date,
                assetRelativePath: try RoomRelativePath("photos/reference-001.jpg"),
                caption: "Reference"
            )
        ]
        let photoBytes = Data("reference-photo".utf8)
        let attachmentBytes = Data("future-attachment".utf8)
        let artifactValues: [(RoomEvidenceArtifactKind, String, String, Data)] = [
            (.capturedRoomDataJSON, "evidence/roomplan/captured-room-data.json", "application/json", Data("raw".utf8)),
            (.capturedRoomJSON, "evidence/roomplan/captured-room.json", "application/json", Data("processed".utf8)),
            (.nativeUSDZ, "evidence/native/RoomScan.usdz", "model/vnd.usdz+zip", Data("native-usdz".utf8)),
        ]
        let photoSource = sourceDirectory.appendingPathComponent("reference-001.jpg")
        let attachmentSource = sourceDirectory.appendingPathComponent("future.bin")
        try photoBytes.write(to: photoSource)
        try attachmentBytes.write(to: attachmentSource)
        var assets: [RoomAssetInput] = [
            RoomAssetInput(sourceURL: photoSource, destination: try RoomRelativePath("photos/reference-001.jpg"), scope: .revision),
            RoomAssetInput(sourceURL: attachmentSource, destination: try RoomRelativePath("attachments/future.bin"), scope: .revision),
        ]
        var presentArtifacts: [(path: String, data: Data)] = []
        var evidenceArtifacts: [RoomEvidenceArtifact] = []
        for (kind, path, mediaType, data) in artifactValues {
            let sourceURL = sourceDirectory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "-"))
            try data.write(to: sourceURL)
            assets.append(RoomAssetInput(sourceURL: sourceURL, destination: try RoomRelativePath(path), scope: .revision))
            presentArtifacts.append((path, data))
            evidenceArtifacts.append(RoomEvidenceArtifact(
                kind: kind,
                status: .present,
                relativePath: try RoomRelativePath(path),
                byteCount: data.count,
                mediaType: mediaType,
                omissionReason: nil,
                sha256Hex: RoomSHA256.hexDigest(of: data)
            ))
        }
        for kind in [RoomEvidenceArtifactKind.rawMesh, .worldMap, .provenance] {
            evidenceArtifacts.append(RoomEvidenceArtifact(
                kind: kind,
                status: .unavailable,
                relativePath: nil,
                byteCount: nil,
                mediaType: nil,
                omissionReason: "Not collected in this test.",
                sha256Hex: nil
            ))
        }
        return EvidenceBackedDraft(
            draft: draft,
            evidence: RoomRevisionEvidencePlan(
                source: .roomPlan,
                artifacts: evidenceArtifacts,
                captureAttemptID: "attempt-001",
                coordinateSpaceEpochID: "epoch-001"
            ),
            assets: assets,
            photoBytes: photoBytes,
            attachmentBytes: attachmentBytes,
            presentArtifacts: presentArtifacts
        )
    }

    private func roomPlanProvenance(sourceID: String = "floor-source-001") -> RoomElementProvenance {
        RoomElementProvenance(
            framework: "RoomPlan",
            sourceIdentifier: sourceID,
            classificationConfidence: .high,
            flattenedAttributeIdentifiers: [],
            captureAttemptID: "attempt-001",
            coordinateSpaceEpochID: "epoch-001"
        )
    }

    private func identityTransform() -> RoomTransform4x4 {
        RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomScanCoreEditTests-\(UUID().uuidString)",
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
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        var bytes: [String: Data] = [:]
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            bytes[relative] = try Data(contentsOf: fileURL)
        }
        return bytes
    }
}

private struct EvidenceBackedDraft {
    let draft: RoomDraft
    let evidence: RoomRevisionEvidencePlan
    let assets: [RoomAssetInput]
    let photoBytes: Data
    let attachmentBytes: Data
    let presentArtifacts: [(path: String, data: Data)]
}
