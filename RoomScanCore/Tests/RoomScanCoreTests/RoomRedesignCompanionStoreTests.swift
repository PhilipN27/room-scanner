import Foundation
import XCTest
@testable import RoomScanCore

final class RoomRedesignCompanionStoreTests: XCTestCase {
    func testSavingAndUpdatingExtensionNeverChangesRevisionBytes() async throws {
        let root = temporaryDirectory("RoomRedesignCompanionStoreTests")
        let companionRoot = temporaryDirectory("RoomRedesignCompanionState")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: companionRoot)
        }
        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_786_492_800)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let before = try bytes(in: root.appendingPathComponent("project-001/revisions/revision-001"))
        let binding = try await store.redesignSourceRevisionBinding(
            projectID: saved.projectID,
            revisionID: saved.headRevisionID
        )
        XCTAssertEqual(
            binding.semanticSHA256,
            try RoomSHA256.hexDigest(ofFile: root.appendingPathComponent("project-001/revisions/revision-001/semantic-model.json"))
        )
        XCTAssertEqual(
            binding.revisionManifestSHA256,
            try RoomSHA256.hexDigest(ofFile: root.appendingPathComponent("project-001/revisions/revision-001/revision.json"))
        )
        let companion = LocalRoomRedesignStore(rootURL: companionRoot)

        let initial = try extensionDocument(binding: binding, source: .suggested)
        try await companion.save(initial, expectedSourceRevision: binding)
        var confirmed = initial
        confirmed.orientation.source = .confirmed
        confirmed.orientation.confidence = 1
        try await companion.save(confirmed, expectedSourceRevision: binding)

        XCTAssertEqual(try bytes(in: root.appendingPathComponent("project-001/revisions/revision-001")), before)
        let reloaded = try await companion.load(sourceRevision: binding)
        XCTAssertEqual(reloaded, confirmed)
        XCTAssertNoThrow(try RoomOrientationReadiness.requireEligible(
            confirmed,
            expectedSourceRevision: binding,
            operation: .aiExport
        ))
    }

    func testCompanionRejectsRevisionAndEpochRebinding() async throws {
        let companionRoot = temporaryDirectory("RoomRedesignCompanionRebinding")
        defer { try? FileManager.default.removeItem(at: companionRoot) }
        let store = LocalRoomRedesignStore(rootURL: companionRoot)
        let binding = sourceRevision()
        var rebound = try extensionDocument(binding: binding, source: .confirmed)
        rebound.sourceRevision.coordinateSpaceEpochID = "epoch-999"

        await XCTAssertThrowsErrorAsync(try await store.save(
            rebound,
            expectedSourceRevision: binding
        ))
    }

    func testLegacyFixtureDocumentsDecodeWithoutChangingBytes() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RoomScanStudio/Fixtures/MockRoom-v1", isDirectory: true)
        let before = try bytes(in: fixture)
        let decoder = RoomJSONCoding.makeDecoder()
        let manifest = try decoder.decode(
            RoomProjectManifest.self,
            from: Data(contentsOf: fixture.appendingPathComponent("manifest.json"))
        )
        let revisionRoot = fixture.appendingPathComponent("revisions/revision-001")
        _ = try decoder.decode(RoomRevisionManifest.self, from: Data(contentsOf: revisionRoot.appendingPathComponent("revision.json")))
        let semantic = try decoder.decode(RoomSemanticSnapshot.self, from: Data(contentsOf: revisionRoot.appendingPathComponent("semantic-model.json")))
        _ = try decoder.decode(RoomAnnotationsDocument.self, from: Data(contentsOf: revisionRoot.appendingPathComponent("annotations.json")))
        _ = try decoder.decode(RoomMeasurementsDocument.self, from: Data(contentsOf: revisionRoot.appendingPathComponent("measurements.json")))
        _ = try decoder.decode(RoomPhotosDocument.self, from: Data(contentsOf: revisionRoot.appendingPathComponent("photos.json")))

        XCTAssertEqual(manifest.schemaVersion, RoomProjectSchemaVersion.v1.rawValue)
        XCTAssertEqual(semantic.objectElements.count, 2)
        XCTAssertEqual(try bytes(in: fixture), before)
    }

    func testPropertyStoreGroupsIndependentProjectsWithoutSpatialInference() async throws {
        let root = temporaryDirectory("RoomPropertyStoreTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRoomPropertyStore(rootURL: root)
        let property = RoomPropertyContainerV1(
            propertyID: "property-001",
            displayName: "Maple Street",
            roomProjectIDs: ["project-001", "project-002"],
            createdAt: Date(timeIntervalSince1970: 1_786_492_800),
            updatedAt: Date(timeIntervalSince1970: 1_786_492_800)
        )

        try await store.save(property)
        let listed = try await store.list()
        let membership = try await store.property(containing: "project-002")
        XCTAssertEqual(listed, [property])
        XCTAssertEqual(membership, property)

        let data = try Data(contentsOf: root.appendingPathComponent("property-001.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "schemaVersion", "propertyID", "displayName", "roomProjectIDs", "createdAt", "updatedAt",
        ])
    }

    private func extensionDocument(
        binding: RoomRedesignSourceRevision,
        source: RoomOrientationSource
    ) throws -> RoomLocalRedesignExtensionV2 {
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: binding,
            input: .init(
                source: source,
                confidence: 0.8,
                entryPositionMeters: .init(x: -1.4, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: .init(
                    minimum: .init(x: -2.7, y: 0, z: -2.1),
                    maximum: .init(x: 2.7, y: 2.7, z: 2.1)
                ),
                referenceWallFeatureID: nil
            )
        )
        return RoomLocalRedesignExtensionV2(
            sourceRevision: binding,
            orientation: orientation,
            redesignIntent: RoomRedesignIntentV2(
                request: "Stage this room while preserving its captured shell.",
                scope: .stage,
                constraints: nil,
                permissions: []
            ),
            propertyMembership: nil,
            conceptMetadata: []
        )
    }

    private func sourceRevision() -> RoomRedesignSourceRevision {
        RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "1", count: 64),
            revisionManifestSHA256: String(repeating: "2", count: 64)
        )
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
                customName: "Test room",
                captureDate: Date(timeIntervalSince1970: 1_786_492_800),
                lastRevisedDate: Date(timeIntervalSince1970: 1_786_492_800),
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

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func bytes(in directory: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {}
    }
}
