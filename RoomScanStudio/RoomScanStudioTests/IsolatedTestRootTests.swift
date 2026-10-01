import Foundation
import XCTest
@testable import RoomScanStudio

final class IsolatedTestRootTests: XCTestCase {
    private let baseArguments = ["--ui-testing", "--reset-local-store"]
    private let token = "test-root_123"

    func testValidTokenNamesEveryRootAndKeepPreservesEverySentinel() throws {
        let manager = try makeFileManager()
        let arguments = baseArguments + ["--isolated-root-token=\(token)"]
        let roots = resolveRoots(arguments, manager: manager)
        XCTAssertEqual(roots.map(\.lastPathComponent), [
            "RoomScanStudio-UI-Testing-Projects-\(token)",
            "RoomScanStudio-UI-Testing-CaptureScratch-\(token)",
            "RoomScanStudio-UI-MeshJob-\(token)",
            "RoomScanStudio-UI-Testing-RedesignState-\(token)",
            "RoomScanStudio-UI-Testing-Properties-\(token)",
            "RoomScanStudio-UI-Testing-ConceptSets-\(token)",
            "RoomScanStudio-UI-Testing-ConceptImportScratch-\(token)",
        ])
        for root in roots {
            XCTAssertTrue(root.lastPathComponent.hasSuffix("-\(token)"), root.path)
            try seed(root)
        }
        let meshRecord = RoomMeshJobRecordRootResolver.resolve(
            arguments: arguments + ["--keep-isolated-root"], fileManager: manager
        )
        try Data("synthetic mesh record".utf8).write(to: meshRecord)
        let kept = resolveRoots(arguments + ["--keep-isolated-root"], manager: manager)
        XCTAssertEqual(kept, roots)
        for root in kept {
            XCTAssertTrue(exists(root.appendingPathComponent("sentinel")), root.path)
        }
        XCTAssertTrue(exists(meshRecord))
        _ = resolveRoots(arguments, manager: manager)
        for root in roots {
            XCTAssertFalse(exists(root.appendingPathComponent("sentinel")), root.path)
        }
        XCTAssertFalse(exists(meshRecord))
        attach("VAL-TRASH-014-token-wipe-and-keep", roots.map(\.lastPathComponent).joined(separator: "\n"))
    }

    func testInvalidTokensAndKeepWithoutTokenUseFreshPIDRoots() throws {
        let manager = try makeFileManager()
        for invalid in ["", String(repeating: "a", count: 65), "/", "..", "a b", "a\n", "é"] {
            let arguments = baseArguments + ["--isolated-root-token=\(invalid)", "--keep-isolated-root"]
            let roots = resolveRoots(arguments, manager: manager)
            for root in roots {
                XCTAssertTrue(root.lastPathComponent.hasSuffix("-\(ProcessInfo.processInfo.processIdentifier)"))
                try seed(root)
            }
            _ = resolveRoots(arguments, manager: manager)
            for root in roots {
                XCTAssertFalse(exists(root.appendingPathComponent("sentinel")), root.path)
            }
        }
        let roots = resolveRoots(baseArguments + ["--keep-isolated-root"], manager: manager)
        for root in roots { try seed(root) }
        _ = resolveRoots(baseArguments + ["--keep-isolated-root"], manager: manager)
        for root in roots { XCTAssertFalse(exists(root.appendingPathComponent("sentinel"))) }
        attach("VAL-TRASH-015-invalid-token", "Invalid tokens and keep without token fall back to fresh PID roots.")
    }

    func testFlagsOutsideIsolatedPairLeaveProductionAndTokenRootsUntouched() throws {
        let manager = try makeFileManager()
        let tokenRoots = resolveRoots(baseArguments + ["--isolated-root-token=\(token)"], manager: manager)
        let tokenScratch = [
            RoomExportScratchRootResolver.resolve(
                arguments: baseArguments + ["--isolated-root-token=\(token)"], fileManager: manager
            ),
            RoomCloudBackupScratchRootResolver.resolve(
                arguments: baseArguments + ["--isolated-root-token=\(token)"], fileManager: manager
            ),
        ]
        for root in tokenRoots + tokenScratch { try seed(root) }
        let productionRoots = resolveRoots([], manager: manager)
        let productionScratch = [
            RoomExportScratchRootResolver.resolve(arguments: [], fileManager: manager),
            RoomCloudBackupScratchRootResolver.resolve(arguments: [], fileManager: manager),
        ]
        for root in productionRoots + productionScratch { try seed(root) }
        for flags in [[], ["--ui-testing"], ["--reset-local-store"]] {
            let roots = resolveRoots(flags + ["--isolated-root-token=\(token)", "--keep-isolated-root"], manager: manager)
            XCTAssertEqual(roots, productionRoots)
            XCTAssertEqual([
                RoomExportScratchRootResolver.resolve(
                    arguments: flags + ["--isolated-root-token=\(token)", "--keep-isolated-root"], fileManager: manager
                ),
                RoomCloudBackupScratchRootResolver.resolve(
                    arguments: flags + ["--isolated-root-token=\(token)", "--keep-isolated-root"], fileManager: manager
                ),
            ], productionScratch)
            for root in productionRoots + tokenRoots + productionScratch + tokenScratch {
                XCTAssertTrue(exists(root.appendingPathComponent("sentinel")), root.path)
            }
        }
        attach("VAL-TRASH-015-production-roots", productionRoots.map(\.path).joined(separator: "\n"))
    }

    func testSymlinkedTokenRootsAreNeverWipedOrFollowed() throws {
        let manager = try makeFileManager()
        let arguments = baseArguments + ["--isolated-root-token=\(token)"]
        let roots = resolveRoots(arguments, manager: manager)
        let external = manager.support.appendingPathComponent("external")
        try seed(external)
        for root in roots {
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: external)
        }
        _ = resolveRoots(arguments, manager: manager)
        for root in roots {
            XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: root.path))
        }
        XCTAssertTrue(exists(external.appendingPathComponent("sentinel")))
        attach("VAL-TRASH-015-symlink-roots", "All token-root symlinks and their external sentinel survived resolution.")
    }

    func testOutsideTemporaryRootAndSymlinkedAncestorAreNotRemoved() throws {
        let manager = try makeFileManager()
        let name = "RoomScanStudio-UI-Testing-Projects-\(token)"
        let external = manager.support.appendingPathComponent(name)
        try seed(external)
        RoomProjectRootResolver.removeIsolatedTestRootIfSafe(
            external, temporaryRoot: manager.temporaryDirectory,
            expectedName: name, fileManager: manager
        )
        let alias = manager.support.appendingPathComponent("tmp-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: manager.temporaryDirectory)
        let actual = manager.temporaryDirectory.appendingPathComponent(name)
        try seed(actual)
        RoomProjectRootResolver.removeIsolatedTestRootIfSafe(
            alias.appendingPathComponent(name), temporaryRoot: alias,
            expectedName: name, fileManager: manager
        )
        XCTAssertTrue(exists(external.appendingPathComponent("sentinel")))
        XCTAssertTrue(exists(actual.appendingPathComponent("sentinel")))
        attach("VAL-TRASH-015-containment", "Internal removal seam: outside-tmp root and root through symlinked ancestor both survived.")
    }

    func testSweepRemovesOnlyOldKnownDirectoriesWithInjectedClock() throws {
        let manager = try makeFileManager()
        let now = Date(timeIntervalSince1970: 1_800_014_400)
        var oldRoots: [URL] = []
        var preserved: [URL] = []
        let external = manager.support.appendingPathComponent("external-old")
        try seed(external)
        try setModification(external, now.addingTimeInterval(-7_200))
        for kind in IsolatedTestRoots.Kind.allCases {
            let prefix = kind.prefix
            let old = manager.temporaryDirectory.appendingPathComponent(prefix + "stale")
            let fresh = manager.temporaryDirectory.appendingPathComponent(prefix + "fresh")
            let boundary = manager.temporaryDirectory.appendingPathComponent(prefix + "boundary")
            let current = manager.temporaryDirectory.appendingPathComponent(prefix + token)
            for root in [old, fresh, boundary, current] { try seed(root) }
            try setModification(old, now.addingTimeInterval(-3_601))
            try setModification(fresh, now.addingTimeInterval(-3_599))
            try setModification(boundary, now.addingTimeInterval(-3_600))
            try setModification(current, now.addingTimeInterval(-7_200))
            oldRoots.append(old)
            preserved += [fresh, boundary, current]
            let link = manager.temporaryDirectory.appendingPathComponent(prefix + "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            preserved.append(link)
        }
        let unrelated = manager.temporaryDirectory.appendingPathComponent("unrelated-stale")
        try seed(unrelated)
        try setModification(unrelated, now.addingTimeInterval(-7_200))
        let regularFile = manager.temporaryDirectory.appendingPathComponent("RoomScanStudio-UI-Testing-Projects-file")
        try Data("not a directory".utf8).write(to: regularFile)
        try setModification(regularFile, now.addingTimeInterval(-7_200))
        IsolatedTestRoots.sweepStaleRoots(
            arguments: baseArguments + ["--isolated-root-token=\(token)"],
            fileManager: manager, now: now
        )
        for root in oldRoots { XCTAssertFalse(exists(root)) }
        for root in preserved {
            XCTAssertTrue(exists(root) || (try? manager.destinationOfSymbolicLink(atPath: root.path)) != nil)
        }
        XCTAssertTrue(exists(unrelated))
        XCTAssertTrue(exists(regularFile))
        XCTAssertTrue(exists(external.appendingPathComponent("sentinel")))
        attach("VAL-TRASH-015-stale-sweep", "Removed \(oldRoots.count) old siblings; fresh, 60-minute boundary, current token, symlinks, files and unrelated names survived.")
    }

    func testSweepIsIgnoredOutsideIsolatedPairAndOnKeptTokenLaunch() throws {
        let manager = try makeFileManager()
        let now = Date(timeIntervalSince1970: 1_800_014_400)
        let old = manager.temporaryDirectory.appendingPathComponent("RoomScanStudio-UI-Testing-Projects-stale")
        try seed(old)
        try setModification(old, now.addingTimeInterval(-7_200))
        for arguments in [
            ["--isolated-root-token=\(token)"],
            ["--ui-testing", "--isolated-root-token=\(token)"],
            ["--reset-local-store", "--isolated-root-token=\(token)"],
            baseArguments + ["--isolated-root-token=\(token)", "--keep-isolated-root"],
        ] {
            IsolatedTestRoots.sweepStaleRoots(arguments: arguments, fileManager: manager, now: now)
            XCTAssertTrue(exists(old))
        }
        IsolatedTestRoots.sweepStaleRoots(
            arguments: baseArguments + ["--keep-isolated-root"], fileManager: manager, now: now
        )
        XCTAssertFalse(exists(old), "Keep without a valid token is ignored, including by the sweep.")
        attach("VAL-TRASH-015-sweep-gating", "Sweep is isolated-only and skips kept token launches; invalid keep is ignored.")
    }

    func testTokenLengthBoundariesAndAdditionalScratchRootsShareSuffix() throws {
        let manager = try makeFileManager()
        for valid in ["a", String(repeating: "Z", count: 64), "Az09_-"] {
            let arguments = baseArguments + ["--isolated-root-token=\(valid)"]
            XCTAssertEqual(IsolatedRootSuffix.resolve(arguments: arguments), valid)
            for root in [
                RoomExportScratchRootResolver.resolve(arguments: arguments, fileManager: manager),
                RoomCloudBackupScratchRootResolver.resolve(arguments: arguments, fileManager: manager),
            ] {
                XCTAssertTrue(root.lastPathComponent.hasSuffix("-\(valid)"))
            }
        }
        attach("VAL-TRASH-014-additional-siblings", "One- and 64-character ASCII tokens accepted; export/cloud scratch use the shared suffix.")
    }

    func testRegisteredFutureSiblingsUseTheSameKeepResetAndNonIsolatedRules() throws {
        let manager = try makeFileManager()
        for kind in [IsolatedTestRoots.Kind.cloudBackupDeletionJournal, .fakeCloudBackup] {
            let arguments = baseArguments + ["--isolated-root-token=\(token)"]
            let root = try XCTUnwrap(IsolatedTestRoots.resolve(kind, arguments: arguments, fileManager: manager))
            XCTAssertEqual(root.lastPathComponent, kind.prefix + token)
            try seed(root)
            _ = IsolatedTestRoots.resolve(kind, arguments: arguments + ["--keep-isolated-root"], fileManager: manager)
            XCTAssertTrue(exists(root.appendingPathComponent("sentinel")))
            for flags in [[], ["--ui-testing"], ["--reset-local-store"]] {
                XCTAssertNil(IsolatedTestRoots.resolve(
                    kind, arguments: flags + ["--isolated-root-token=\(token)"], fileManager: manager
                ))
                XCTAssertTrue(exists(root.appendingPathComponent("sentinel")))
            }
            _ = IsolatedTestRoots.resolve(kind, arguments: arguments, fileManager: manager)
            XCTAssertFalse(exists(root))
        }
        attach("VAL-TRASH-014-future-siblings", "Journal and fake-backup sibling kinds are registered for Milestone 2 and obey the shared token policy.")
    }

    private func resolveRoots(_ arguments: [String], manager: RootTestFileManager) -> [URL] {
        let project = RoomProjectRootResolver.resolve(arguments: arguments, fileManager: manager)
        let extensions = RoomRedesignLocalRootResolver.resolve(
            arguments: arguments, projectRootURL: project, fileManager: manager
        )
        let concepts = RoomAIRedesignRootResolver.resolve(
            arguments: arguments, projectRootURL: project, fileManager: manager
        )
        return [
            project,
            RoomCaptureScratchRootResolver.resolve(arguments: arguments, fileManager: manager),
            RoomMeshJobRecordRootResolver.resolve(arguments: arguments, fileManager: manager).deletingLastPathComponent(),
            extensions.redesign, extensions.properties,
            concepts.concepts, concepts.importScratch,
        ]
    }

    private func setModification(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeFileManager() throws -> RootTestFileManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolated-root-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let manager = RootTestFileManager(root: root)
        try FileManager.default.createDirectory(at: manager.temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manager.support, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return manager
    }

    private func seed(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic sentinel".utf8).write(to: root.appendingPathComponent("sentinel"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func attach(_ name: String, _ facts: String) {
        let attachment = XCTAttachment(string: facts)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class RootTestFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    var support: URL { root.appendingPathComponent("Application Support", isDirectory: true) }
    override var temporaryDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [support] : super.urls(for: directory, in: domainMask)
    }
}
