import Foundation
import XCTest
@testable import RoomScanCore

final class CompanionRemovalTests: XCTestCase {
    private let fileManager = FileManager.default

    func testAbsentCompanionRemovalCreatesNoDirectories() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let redesignRoot = temporary.appendingPathComponent("redesign")
        let conceptRoot = temporary.appendingPathComponent("concepts")
        let propertyRoot = temporary.appendingPathComponent("properties")
        let redesign = LocalRoomRedesignStore(rootURL: redesignRoot)
        let concepts = LocalRoomConceptStore(
            rootURL: conceptRoot,
            sourcePackageRootURL: temporary.appendingPathComponent("absent-source")
        )
        let properties = LocalRoomPropertyStore(rootURL: propertyRoot)

        for _ in 0..<2 {
            let removedRedesign = try await redesign.removeAll(projectID: "project-001")
            let removedConcepts = try await concepts.removeAll(projectID: "project-001")
            let detached = try await properties.detach(projectID: "project-001")
            XCTAssertFalse(removedRedesign)
            XCTAssertFalse(removedConcepts)
            XCTAssertEqual(detached, [])
        }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: temporary.path), [])
        #if canImport(Darwin)
        let attachment = XCTAttachment(string: "Repeated absent companion removals returned false/empty and created no directories.")
        attachment.name = "VAL-TRASH-010-absent-companion-removal"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }

    func testCompanionRemovalRejectsUnsafeProjectIdentifiers() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let redesign = LocalRoomRedesignStore(rootURL: temporary.appendingPathComponent("redesign"))
        let concepts = LocalRoomConceptStore(
            rootURL: temporary.appendingPathComponent("concepts"),
            sourcePackageRootURL: temporary.appendingPathComponent("source")
        )
        let properties = LocalRoomPropertyStore(rootURL: temporary.appendingPathComponent("properties"))
        for identifier in ["", ".", "..", "../outside", "project/child", "/absolute"] {
            await assertProjectStoreFailure { _ = try await redesign.removeAll(projectID: identifier) }
            await assertConceptFailure { _ = try await concepts.removeAll(projectID: identifier) }
            await assertProjectStoreFailure { _ = try await properties.detach(projectID: identifier) }
        }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: temporary.path), [])
    }

    func testRedesignRemoveAllIsProjectBoundedAndIdempotent() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("redesign")
        try writeCanary(at: root.appendingPathComponent("project-001/revision-001.json"))
        try writeCanary(at: root.appendingPathComponent("project-001/nested/.hidden-state"))
        let sibling = root.appendingPathComponent("project-002/revision-001.json")
        try writeCanary(at: sibling)
        let original = try Data(contentsOf: sibling)
        let store = LocalRoomRedesignStore(rootURL: root)

        let removed = try await store.removeAll(projectID: "project-001")
        let removedAgain = try await store.removeAll(projectID: "project-001")
        XCTAssertTrue(removed)
        XCTAssertFalse(removedAgain)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("project-001").path))
        XCTAssertEqual(try Data(contentsOf: sibling), original)
    }

    func testRedesignRemovalRejectsRootProjectAndRecursiveSymlinks() async throws {
        for linkPath in ["", "project-001", "project-001/nested/link", "project-001/.hidden-link"] {
            let temporary = try makeTemporaryDirectory()
            defer { try? fileManager.removeItem(at: temporary) }
            let root = temporary.appendingPathComponent("redesign")
            let external = temporary.appendingPathComponent("external")
            let externalCanary = external.appendingPathComponent("keep")
            try writeCanary(at: externalCanary)
            let link = linkPath.isEmpty ? root : root.appendingPathComponent(linkPath)
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: external)
            let store = LocalRoomRedesignStore(rootURL: root)

            await assertProjectStoreFailure { _ = try await store.removeAll(projectID: "project-001") }
            XCTAssertEqual(try Data(contentsOf: externalCanary), Self.canary)
            XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.path), external.path)
        }
    }

    func testDanglingRootSymlinksAreNotMistakenForAbsence() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let missing = temporary.appendingPathComponent("missing")
        let redesignRoot = temporary.appendingPathComponent("redesign")
        let conceptRoot = temporary.appendingPathComponent("concepts")
        let propertyRoot = temporary.appendingPathComponent("properties")
        for root in [redesignRoot, conceptRoot, propertyRoot] {
            try fileManager.createSymbolicLink(at: root, withDestinationURL: missing)
        }
        let redesign = LocalRoomRedesignStore(rootURL: redesignRoot)
        let concepts = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: temporary.appendingPathComponent("source"))
        let properties = LocalRoomPropertyStore(rootURL: propertyRoot)
        await assertProjectStoreFailure { _ = try await redesign.removeAll(projectID: "project-001") }
        await assertConceptFailure { _ = try await concepts.removeAll(projectID: "project-001") }
        await assertProjectStoreFailure { _ = try await properties.detach(projectID: "project-001") }
        XCTAssertFalse(fileManager.fileExists(atPath: missing.path))
    }

    func testConceptRemoveAllRemovesImportedSetsAcrossRevisionsAndKeepsOtherProjects() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("concepts")
        let sourceRoot = temporary.appendingPathComponent("source")
        try writeCanary(at: sourceRoot.appendingPathComponent("immutable"))
        let store = LocalRoomConceptStore(rootURL: root, sourcePackageRootURL: sourceRoot)
        let first = sourceRevision()
        var second = first
        second.revisionID = "revision-002"
        second.revisionManifestSHA256 = String(repeating: "c", count: 64)
        var other = first
        other.projectID = "project-002"
        for source in [first, second, other] {
            _ = try await store.importConceptSet(
                makeImport(source: source),
                context: .init(expectedSourceRevision: source, currentCanonicalCameraIDs: [])
            )
        }
        let siblingManifest = conceptDirectory(root: root, source: other, conceptID: "concept-001").appendingPathComponent("manifest.json")
        let siblingBefore = try Data(contentsOf: siblingManifest)

        let removed = try await store.removeAll(projectID: first.projectID)
        let removedAgain = try await store.removeAll(projectID: first.projectID)
        XCTAssertTrue(removed)
        XCTAssertFalse(removedAgain)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(first.projectID).path))
        XCTAssertEqual(try Data(contentsOf: siblingManifest), siblingBefore)
        XCTAssertEqual(try Data(contentsOf: sourceRoot.appendingPathComponent("immutable")), Self.canary)
    }

    func testConceptRemoveAllRequiresOwnershipMarkerAndRefusesSymlink() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("concepts")
        let source = sourceRevision()
        let unmarked = conceptDirectory(root: root, source: source, conceptID: "a-unmarked")
        try writeCanary(at: unmarked.appendingPathComponent("keep"))
        let mismatched = conceptDirectory(root: root, source: source, conceptID: "b-mismatched")
        var wrongOwner = source
        wrongOwner.projectID = "project-other"
        try seedOwnedConcept(at: mismatched, source: wrongOwner, conceptID: "b-mismatched")
        let mismatchedBefore = try Data(contentsOf: mismatched.appendingPathComponent(Self.ownershipFilename))
        let external = temporary.appendingPathComponent("external")
        try writeCanary(at: external.appendingPathComponent("keep"))
        let linked = conceptDirectory(root: root, source: source, conceptID: "c-linked")
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: external)
        let valid = conceptDirectory(root: root, source: source, conceptID: "z-owned")
        try seedOwnedConcept(at: valid, source: source, conceptID: "z-owned")
        let store = LocalRoomConceptStore(rootURL: root, sourcePackageRootURL: temporary.appendingPathComponent("source"))

        await assertConceptFailure { _ = try await store.removeAll(projectID: source.projectID) }
        XCTAssertFalse(fileManager.fileExists(atPath: valid.path), "Good children must be attempted after bad children.")
        XCTAssertEqual(try Data(contentsOf: unmarked.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try Data(contentsOf: mismatched.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try Data(contentsOf: mismatched.appendingPathComponent(Self.ownershipFilename)), mismatchedBefore)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linked.path), external.path)
        await assertConceptFailure { _ = try await store.removeAll(projectID: source.projectID) }
    }

    func testConceptCleanupRequiresExactCanonicalSourceAndDirectoryOwnership() async throws {
        for mutation in ["revision", "digest", "concept", "transaction", "format", "unknown-key", "noncanonical", "marker-link"] {
            let temporary = try makeTemporaryDirectory()
            defer { try? fileManager.removeItem(at: temporary) }
            let root = temporary.appendingPathComponent("concepts")
            let source = sourceRevision()
            let directory = conceptDirectory(root: root, source: source, conceptID: "concept-001")
            try seedOwnedConcept(at: directory, source: source, conceptID: "concept-001")
            let marker = directory.appendingPathComponent(Self.ownershipFilename)
            var ownership = Ownership(sourceRevision: source, conceptSetID: "concept-001")
            switch mutation {
            case "revision": ownership.sourceRevision.revisionID = "revision-other"
            case "digest": ownership.sourceRevision.revisionManifestSHA256 = String(repeating: "d", count: 64)
            case "concept": ownership.conceptSetID = "concept-other"
            case "transaction": ownership.transactionID = "../unsafe"
            case "format": ownership.formatVersion = "unknown"
            default: break
            }
            var markerBytes = try RoomConceptSetCanonicalJSON.encode(ownership)
            if mutation == "unknown-key" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: markerBytes) as? [String: Any])
                object["extraOwner"] = "untrusted"
                markerBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            } else if mutation == "noncanonical" {
                markerBytes.append(Data("\n".utf8))
            }
            try markerBytes.write(to: marker)
            if mutation == "marker-link" {
                let externalMarker = temporary.appendingPathComponent("external-marker")
                try markerBytes.write(to: externalMarker)
                try fileManager.removeItem(at: marker)
                try fileManager.createSymbolicLink(at: marker, withDestinationURL: externalMarker)
            }
            let store = LocalRoomConceptStore(rootURL: root, sourcePackageRootURL: temporary.appendingPathComponent("source"))

            await assertConceptFailure { _ = try await store.removeAll(projectID: source.projectID) }
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), Self.canary, mutation)
            XCTAssertEqual(try Data(contentsOf: marker), markerBytes, mutation)
        }
    }

    func testConceptCleanupRejectsRecursiveLinksAndStillRemovesSafeSiblings() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("concepts")
        let source = sourceRevision()
        let unsafe = conceptDirectory(root: root, source: source, conceptID: "a-unsafe")
        let safe = conceptDirectory(root: root, source: source, conceptID: "z-safe")
        try seedOwnedConcept(at: unsafe, source: source, conceptID: "a-unsafe")
        try seedOwnedConcept(at: safe, source: source, conceptID: "z-safe")
        let external = temporary.appendingPathComponent("external")
        try writeCanary(at: external.appendingPathComponent("keep"))
        let nested = unsafe.appendingPathComponent("nested/.hidden-link")
        try fileManager.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(at: nested, withDestinationURL: external)
        let store = LocalRoomConceptStore(rootURL: root, sourcePackageRootURL: temporary.appendingPathComponent("source"))

        await assertConceptFailure { _ = try await store.removeAll(projectID: source.projectID) }
        XCTAssertFalse(fileManager.fileExists(atPath: safe.path))
        XCTAssertEqual(try Data(contentsOf: unsafe.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: nested.path), external.path)
    }

    func testConceptCleanupRejectsSymlinkAtEachStorePathLevel() async throws {
        let source = sourceRevision()
        for suffix in ["", source.projectID, "\(source.projectID)/\(source.revisionID)", "\(source.projectID)/\(source.revisionID)/\(source.revisionManifestSHA256)"] {
            let temporary = try makeTemporaryDirectory()
            defer { try? fileManager.removeItem(at: temporary) }
            let root = temporary.appendingPathComponent("concepts")
            let external = temporary.appendingPathComponent("external")
            try writeCanary(at: external.appendingPathComponent("keep"))
            let link = suffix.isEmpty ? root : root.appendingPathComponent(suffix)
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: external)
            let store = LocalRoomConceptStore(rootURL: root, sourcePackageRootURL: temporary.appendingPathComponent("source"))

            await assertConceptFailure { _ = try await store.removeAll(projectID: source.projectID) }
            XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("keep")), Self.canary)
            XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.path), external.path)
        }
    }

    func testConceptCleanupRejectsSourceStoreOverlap() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source")
        let root = sourceRoot.appendingPathComponent("concepts")
        try seedOwnedConcept(
            at: conceptDirectory(root: root, source: sourceRevision(), conceptID: "concept-001"),
            source: sourceRevision(),
            conceptID: "concept-001"
        )
        let store = LocalRoomConceptStore(rootURL: root, sourcePackageRootURL: sourceRoot)
        await assertConceptFailure { _ = try await store.removeAll(projectID: "project-001") }
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("project-001").path))
    }

    func testPropertyDetachRemovesEveryMembershipWithoutDeletingProperties() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("properties")
        let originals = [
            property("property-001", members: ["project-a", "project-001", "project-b"]),
            property("property-002", members: ["project-001"]),
            property("property-003", members: ["project-c"]),
        ]
        for property in originals {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try RoomRedesignCanonicalJSON.encode(property).write(to: root.appendingPathComponent("\(property.propertyID).json"))
        }
        let unrelatedURL = root.appendingPathComponent("property-003.json")
        let unrelatedBefore = try Data(contentsOf: unrelatedURL)
        let store = LocalRoomPropertyStore(rootURL: root)

        let detached = try await store.detach(projectID: "project-001")
        XCTAssertEqual(detached, ["property-001", "property-002"])
        for original in originals {
            var expected = original
            expected.roomProjectIDs.removeAll { $0 == "project-001" }
            let bytes = try Data(contentsOf: root.appendingPathComponent("\(original.propertyID).json"))
            XCTAssertEqual(bytes, try RoomRedesignCanonicalJSON.encode(expected))
        }
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), unrelatedBefore)
        let detachedAgain = try await store.detach(projectID: "project-001")
        XCTAssertEqual(detachedAgain, [])
        let listed = try await store.list()
        XCTAssertEqual(listed.count, 3)
    }

    func testPropertyDetachRefusesRootAndFileSymlinksWithoutChangingExternalBytes() async throws {
        for rootLink in [true, false] {
            let temporary = try makeTemporaryDirectory()
            defer { try? fileManager.removeItem(at: temporary) }
            let root = temporary.appendingPathComponent("properties")
            let external = temporary.appendingPathComponent("external")
            let externalFile = external.appendingPathComponent("property-001.json")
            try fileManager.createDirectory(at: external, withIntermediateDirectories: false)
            let original = try RoomRedesignCanonicalJSON.encode(property("property-001", members: ["project-001"]))
            try original.write(to: externalFile)
            let link: URL
            if rootLink {
                link = root
                try fileManager.createSymbolicLink(at: root, withDestinationURL: external)
            } else {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
                link = root.appendingPathComponent("property-001.json")
                try fileManager.createSymbolicLink(at: link, withDestinationURL: externalFile)
            }
            let store = LocalRoomPropertyStore(rootURL: root)
            await assertProjectStoreFailure { _ = try await store.detach(projectID: "project-001") }
            XCTAssertEqual(try Data(contentsOf: externalFile), original)
            XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: link.path))
        }
    }

    func testPropertyDetachValidatesAllFilesBeforeChangingAnyMembership() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("properties")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let good = root.appendingPathComponent("property-001.json")
        let original = try RoomRedesignCanonicalJSON.encode(property("property-001", members: ["project-001"]))
        try original.write(to: good)
        let invalid = root.appendingPathComponent("property-999.json")
        try Self.canary.write(to: invalid)
        let store = LocalRoomPropertyStore(rootURL: root)

        await assertProjectStoreFailure { _ = try await store.detach(projectID: "project-001") }
        XCTAssertEqual(try Data(contentsOf: good), original)
        XCTAssertEqual(try Data(contentsOf: invalid), Self.canary)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("CompanionRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func writeCanary(at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.canary.write(to: url)
    }

    private func sourceRevision() -> RoomRedesignSourceRevision {
        .init(
            projectID: "project-001",
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
    }

    private func conceptDirectory(root: URL, source: RoomRedesignSourceRevision, conceptID: String) -> URL {
        root.appendingPathComponent(source.projectID)
            .appendingPathComponent(source.revisionID)
            .appendingPathComponent(source.revisionManifestSHA256)
            .appendingPathComponent(conceptID)
    }

    private func seedOwnedConcept(at directory: URL, source: RoomRedesignSourceRevision, conceptID: String) throws {
        try writeCanary(at: directory.appendingPathComponent("keep"))
        try RoomConceptSetCanonicalJSON.encode(Ownership(sourceRevision: source, conceptSetID: conceptID))
            .write(to: directory.appendingPathComponent(Self.ownershipFilename))
    }

    private func makeImport(source: RoomRedesignSourceRevision) -> RoomConceptSetImport {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let attachment = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: png),
            byteCount: UInt64(png.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedLooseFile,
            mapping: .unmatched
        )
        return .init(
            conceptSet: .init(
                conceptSetID: "concept-001",
                sourceRevision: source,
                request: "Synthetic cleanup concept.",
                scope: .stage,
                provider: nil,
                sourceAIRoomPackage: nil,
                importProvenance: .init(kind: .looseLocalFile, sourceFilename: "synthetic.png"),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                importedAt: Date(timeIntervalSince1970: 1_700_000_100),
                attachments: [attachment],
                comments: [],
                approvalState: .pending,
                archiveState: .active
            ),
            attachments: [.init(attachmentID: attachment.attachmentID, data: png)]
        )
    }

    private func property(_ id: String, members: [String]) -> RoomPropertyContainerV1 {
        .init(
            propertyID: id,
            displayName: id,
            roomProjectIDs: members,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func assertProjectStoreFailure(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected guarded cleanup to fail.")
        } catch {
            XCTAssertNotNil(error as? RoomProjectStoreError, "Expected a typed project-store error, got \(error).")
        }
    }

    private func assertConceptFailure(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected guarded cleanup to fail.")
        } catch {
            XCTAssertNotNil(error as? RoomConceptSetError, "Expected a typed Concept Set error, got \(error).")
        }
    }

    private struct Ownership: Codable {
        var formatVersion = "roomscan-concept-store-ownership-v1"
        var sourceRevision: RoomRedesignSourceRevision
        var conceptSetID: String
        var transactionID = "transaction-001"
    }

    private static let ownershipFilename = ".roomscan-concept-ownership.json"
    private static let canary = Data("synthetic-cleanup-canary".utf8)
}
