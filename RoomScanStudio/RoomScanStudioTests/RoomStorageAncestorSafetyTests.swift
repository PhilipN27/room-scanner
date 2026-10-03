import Foundation
import RoomScanCore
import XCTest
@testable import RoomScanStudio

/// A real iPhone reports container paths as `/var/mobile/...`, and
/// `resolvingSymlinksInPath()` strips `/private` back to that form, so every
/// production root passes through the root-owned `/var -> private/var` link.
/// Simulator containers have no such ancestor. These tests route each store
/// through the host's root-owned `/tmp -> private/tmp` link to reproduce the
/// device shape, while app-created links must keep failing closed.
@MainActor
final class RoomStorageAncestorSafetyTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let systemLink = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let attributes = try fileManager.attributesOfItem(atPath: systemLink.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "Precondition: host /tmp is a symlink.")
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.intValue, 0, "Precondition: host /tmp is root-owned.")
        root = systemLink.appendingPathComponent("RoomStorageAncestorSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root {
            try fileManager.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    func testPrivatePrefixStrippedContainerPathPassesThroughRootOwnedSystemLink() {
        let resolved = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true).resolvingSymlinksInPath()
        XCTAssertEqual(resolved.path, "/var/tmp", "Foundation strips /private, recreating the device path form.")
        XCTAssertTrue(RoomStorageAncestorSafety.existingAncestorsAreSafe(of: resolved, fileManager: fileManager))
        XCTAssertTrue(RoomStorageAncestorSafety.existingAncestorsAreSafe(
            of: root.appendingPathComponent("missing/deeper"), fileManager: fileManager
        ))
    }

    func testAppCreatedLinksStillFailAtEveryDepth() throws {
        let external = root.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: false)
        let ancestorLink = root.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createSymbolicLink(at: ancestorLink, withDestinationURL: external)
        XCTAssertFalse(RoomStorageAncestorSafety.existingAncestorsAreSafe(
            of: ancestorLink.appendingPathComponent("records/a.json"), fileManager: fileManager
        ))
        XCTAssertFalse(RoomStorageAncestorSafety.existingAncestorsAreSafe(of: ancestorLink, fileManager: fileManager))

        let dangling = root.appendingPathComponent("dangling")
        try fileManager.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertFalse(RoomStorageAncestorSafety.existingAncestorsAreSafe(
            of: dangling.appendingPathComponent("child"), fileManager: fileManager
        ))
        XCTAssertFalse(RoomStorageAncestorSafety.existingAncestorsAreSafe(
            of: URL(string: "relative/path")!, fileManager: fileManager
        ))
    }

    /// Root ownership alone is not trust: a root-owned link below `/` stays
    /// rejected, so only the top-level system aliases are accepted.
    func testRootOwnedLinkBelowTopLevelIsStillRejected() throws {
        let directory = URL(fileURLWithPath: "/usr/bin", isDirectory: true)
        let entries = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        let link = entries.lazy.map { directory.appendingPathComponent($0) }.first { candidate in
            guard let attributes = try? self.fileManager.attributesOfItem(atPath: candidate.path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeSymbolicLink
                && (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0
        }
        guard let link else {
            throw XCTSkip("The host /usr/bin has no root-owned symlink to exercise.")
        }
        XCTAssertFalse(RoomStorageAncestorSafety.existingAncestorsAreSafe(of: link, fileManager: fileManager), link.path)
        XCTAssertFalse(RoomStorageAncestorSafety.existingAncestorsAreSafe(
            of: link.appendingPathComponent("child"), fileManager: fileManager
        ), link.path)
    }

    /// No unprivileged test can create a link directly under `/`, so a fake
    /// file manager reports one. The root-owned case is the positive control.
    func testTopLevelLinkIsTrustedOnlyWhenRootOwned() {
        let path = "/roomscan-synthetic-top-level-link"
        let child = URL(fileURLWithPath: path).appendingPathComponent("child")
        XCTAssertTrue(RoomStorageAncestorSafety.existingAncestorsAreSafe(
            of: child, fileManager: TopLevelLinkFileManager(linkPath: path, owner: 0)
        ))
        XCTAssertFalse(RoomStorageAncestorSafety.existingAncestorsAreSafe(
            of: child, fileManager: TopLevelLinkFileManager(linkPath: path, owner: 501)
        ))
    }

    func testCloudBackupDeletionJournalRoundTripsUnderSystemLinkedAncestor() throws {
        let journalRoot = root.appendingPathComponent("CloudBackupDeletionJournal", isDirectory: true)
        let journal = RoomCloudBackupDeletionJournal(rootURL: journalRoot)
        XCTAssertEqual(try journal.pendingRequests(), [])
        let request = RoomCloudBackupDeletionRequest(
            projectID: "ui-project-001",
            containerIdentifier: "iCloud.org.roomscanstudio.test",
            displayName: "Synthetic ui-project-001",
            requestedAt: Date(timeIntervalSince1970: 1_800_014_400),
            knownRecordNames: []
        )
        try journal.replace(request)
        XCTAssertEqual(try journal.load(projectID: "ui-project-001"), request)
        XCTAssertEqual(try journal.pendingRequests(), [request])
        try journal.remove(projectID: "ui-project-001")
        XCTAssertNil(try journal.load(projectID: "ui-project-001"))

        let external = root.appendingPathComponent("external-journal", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: false)
        let linkedRoot = root.appendingPathComponent("linked-journal", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: external)
        let linked = RoomCloudBackupDeletionJournal(rootURL: linkedRoot.appendingPathComponent("journal"))
        XCTAssertThrowsError(try linked.replace(request)) { error in
            XCTAssertEqual(error as? RoomCloudBackupDeletionJournalError, .unsafeJournal)
        }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: external.path), [])
    }

    func testAIProvenanceRegistryReadsUnderSystemLinkedAncestor() throws {
        let provenanceRoot = root.appendingPathComponent("AIRedesignProvenance", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Projects", isDirectory: true)
        try fileManager.createDirectory(at: provenanceRoot, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let registry = RoomAIConceptPackageProvenanceRegistry(rootURL: provenanceRoot, sourcePackageRootURL: sourceRoot)
        let source = RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "1", count: 64),
            revisionManifestSHA256: String(repeating: "2", count: 64)
        )
        XCTAssertEqual(try registry.bindings(for: source), [])
        XCTAssertEqual(try registry.canonicalManifestData(for: source), [])

        let escape = root.appendingPathComponent("escape", isDirectory: true)
        try fileManager.createSymbolicLink(at: escape, withDestinationURL: sourceRoot)
        let escaped = RoomAIConceptPackageProvenanceRegistry(
            rootURL: escape.appendingPathComponent("AIRedesignProvenance", isDirectory: true),
            sourcePackageRootURL: sourceRoot
        )
        XCTAssertThrowsError(try escaped.bindings(for: source))
    }

    func testProfessionalSyncJournalOpensUnderSystemLinkedAncestor() throws {
        let journal = try ProfessionalProjectSyncJournal(
            rootURL: root.appendingPathComponent("ProfessionalSyncJournal", isDirectory: true)
        )
        XCTAssertNil(try journal.load(localProjectID: "project-001"))
    }

    func testPublicationOperationJournalOpensUnderSystemLinkedAncestor() throws {
        let journal = try PublicationOperationJournal(
            rootURL: root.appendingPathComponent("PublicationOperationJournal", isDirectory: true)
        )
        XCTAssertNil(try journal.load(operationID: "operation-0000000000000001"))
    }

    func testProfessionalRecoveryAcceptsArchiveUnderSystemLinkedAncestor() async throws {
        let archive = root.appendingPathComponent("archive.zip")
        try Data("synthetic".utf8).write(to: archive)
        let coordinator = ProfessionalProjectRecoveryCoordinator(fileManager: fileManager)
        do {
            _ = try await coordinator.recoverDownloadedArchive(
                archiveURL: archive,
                recovery: ProfessionalProjectSyncRecovery(
                    projectID: "prj_0000000000000001",
                    revisionID: "rev_0000000000000001",
                    branchState: .canonical,
                    workingSetManifestSHA256: String(repeating: "a", count: 64),
                    archiveSHA256: String(repeating: "b", count: 64),
                    archiveByteCount: 1
                ),
                target: .original
            )
            XCTFail("No dependencies are composed, so recovery must stop after the path check.")
        } catch {
            XCTAssertEqual(
                error as? ProfessionalProjectSyncError, .sourceUnavailable,
                "The archive path itself must pass the ancestor check; got \(error)."
            )
        }
    }
}

private final class TopLevelLinkFileManager: FileManager {
    private let linkPath: String
    private let owner: Int

    init(linkPath: String, owner: Int) {
        self.linkPath = linkPath
        self.owner = owner
        super.init()
    }

    override func destinationOfSymbolicLink(atPath path: String) throws -> String {
        path == linkPath ? "private/synthetic" : try super.destinationOfSymbolicLink(atPath: path)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard path == linkPath else { return try super.attributesOfItem(atPath: path) }
        return [.type: FileAttributeType.typeSymbolicLink, .ownerAccountID: NSNumber(value: owner)]
    }

    override func fileExists(atPath path: String) -> Bool {
        path == linkPath || super.fileExists(atPath: path)
    }
}
