import Foundation
import XCTest

extension RoomScanStudioUITests {
    func testTrashSurvivesTokenRelaunchAndDeletedIndexWithIdenticalPurgeDate() throws {
        executionTimeAllowance = 300
        let token = String(UUID().uuidString.prefix(12))
        var app = launchTrashRelaunchApp(token: token, clock: 1_800_014_400, valID: "VAL-TRASH-016")
        defer { app.terminate() }
        saveTrashTestRooms(2, in: app)
        openTrashTestProject("ui-project-001", in: app)
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-016", slug: "initial-trash")
        selectTrashTestFilter("Trash", in: app)
        assertTrashRelaunchMembership(in: app, present: ["ui-project-001"], absent: ["ui-project-002"])
        let purgeDate = trashTestPurgeLabel("ui-project-001", in: app)
        attachTrashScreenshot(app, "VAL-TRASH-016", "before-relaunch-purge-date")
        let roots = try XCTUnwrap(trashTestRoots(token: token))
        let metadata = try trashRelaunchMetadata(roots, projectID: "ui-project-001", valID: "VAL-TRASH-016")
        XCTAssertEqual(metadata["trashedAt"] as? String, "2027-01-15T12:00:00Z")
        let before = try trashTestBytes(roots.root("Projects"), under: roots.temporary)
        try attachTrashTestListing(roots, "VAL-TRASH-016", "before-relaunch-disk-listing")
        app.terminate()

        app = launchTrashRelaunchApp(token: token, keepRoot: true, clock: 1_800_014_400, valID: "VAL-TRASH-016")
        openTrashRelaunchLibrary(in: app)
        assertTrashRelaunchMembershipAndDate(purgeDate, in: app)
        attachTrashScreenshot(app, "VAL-TRASH-016", "same-token-kept-trash-identical-purge-date")
        XCTAssertEqual(try trashTestBytes(roots.root("Projects"), under: roots.temporary), before)
        app.terminate()

        // SwiftData is disposable. Remove only this isolated app's named
        // index and SQLite companions while the app is stopped, never packages.
        try removeTrashRelaunchIndex(in: roots)
        app = launchTrashRelaunchApp(token: token, keepRoot: true, clock: 1_800_014_400, valID: "VAL-TRASH-016")
        openTrashRelaunchLibrary(in: app)
        assertTrashRelaunchMembershipAndDate(purgeDate, in: app)
        attachTrashScreenshot(app, "VAL-TRASH-016", "deleted-index-rebuilt-trash-identical-purge-date")
        XCTAssertEqual(try trashTestBytes(roots.root("Projects"), under: roots.temporary), before,
                       "Index rebuilding must not rewrite authoritative packages.")
        _ = try trashRelaunchMetadata(roots, projectID: "ui-project-001", valID: "VAL-TRASH-016")
        try attachTrashTestListing(roots, "VAL-TRASH-016", "after-deleted-index-rebuild-disk-listing")
    }

    func testTrashReaperOnTokenRelaunchHonorsBoundaryAndPreservesRecentTrashAndActiveProject() throws {
        executionTimeAllowance = 900
        // Exact contract: A expires at 30d+1s, B remains active, Trash empties.
        try runTrashRelaunchExpiryScenario(projectCount: 2, expiryInterval: 2_592_001)
        // Stronger feature case: at midday UTC +31d, only A expires while
        // recent trash B and active C retain every package/companion byte.
        try runTrashRelaunchExpiryScenario(projectCount: 3, expiryInterval: 31 * 86_400)
    }

    private func runTrashRelaunchExpiryScenario(projectCount: Int, expiryInterval: Int) throws {
        let token = String(UUID().uuidString.prefix(12))
        let ids = (1...projectCount).map { String(format: "ui-project-%03d", $0) }
        let epoch: Int = 1_800_014_400 // Midday UTC, independent of the real date.
        var app = launchTrashRelaunchApp(token: token, clock: epoch, valID: "VAL-TRASH-027")
        defer { app.terminate() }
        saveTrashTestRooms(projectCount, in: app)
        for id in ids {
            openTrashTestProject(id, in: app)
            seedTrashTestRedesignThroughUI(in: app)
            backToTrashTestLibrary(in: app)
        }
        let roots = try XCTUnwrap(trashTestRoots(token: token))
        for id in ids {
            try seedTrashTestOwnedConcept(in: roots, projectID: id, token: token)
        }
        openTrashTestProject("ui-project-001", in: app)
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-027", slug: "expired-candidate-A")
        selectTrashTestFilter("Trash", in: app)
        let aDate = trashTestPurgeLabel("ui-project-001", in: app)
        assertTrashRelaunchMembership(in: app, present: ["ui-project-001"], absent: Array(ids.dropFirst()))
        let aBytes = try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-001")
        let bActiveBytes = try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-002")
        let cBytes = projectCount == 3
            ? try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-003") : nil
        try attachTrashTestListing(roots, "VAL-TRASH-027", "seeded-\(projectCount)-projects-and-companions")
        app.terminate()

        // Negative control required by VAL-TRASH-027: 29 days 23 hours
        // cannot purge A. In the three-project scenario, trash B now so it
        // remains recent when A expires.
        app = launchTrashRelaunchApp(token: token, keepRoot: true, clock: epoch + 2_588_400, valID: "VAL-TRASH-027")
        openTrashRelaunchLibrary(in: app)
        selectTrashTestFilter("Trash", in: app)
        XCTAssertEqual(trashTestPurgeLabel("ui-project-001", in: app), aDate)
        assertTrashRelaunchMembership(in: app, present: ["ui-project-001"], absent: Array(ids.dropFirst()))
        attachTrashScreenshot(app, "VAL-TRASH-027", "29-days-23-hours-retains-A-negative-control")
        XCTAssertEqual(try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-001"), aBytes)
        XCTAssertEqual(try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-002"), bActiveBytes)
        if let cBytes {
            XCTAssertEqual(try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-003"), cBytes)
        }
        selectTrashTestFilter("Active", in: app)
        assertTrashRelaunchMembership(in: app, present: Array(ids.dropFirst()), absent: ["ui-project-001"])
        var bDate: String?
        if projectCount == 3 {
            openTrashTestProject("ui-project-002", in: app)
            moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-027", slug: "recent-trash-B")
            selectTrashTestFilter("Trash", in: app)
            bDate = trashTestPurgeLabel("ui-project-002", in: app)
        }
        let bBytes = try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-002")
        try attachTrashTestListing(roots, "VAL-TRASH-027", "negative-control-before-expiry")
        app.terminate()

        // Check disk while still on Home: no library tap or manual refresh
        // can be responsible for the purge. The deadline starts at Home.
        app = launchTrashRelaunchApp(token: token, keepRoot: true, clock: epoch + expiryInterval, valID: "VAL-TRASH-027")
        try assertTrashRelaunchHomePurge(roots, in: app, slug: "\(expiryInterval)-seconds-home-purge")
        openTrashRelaunchLibrary(in: app)
        if let bDate {
            assertTrashRelaunchOnlyRecentTrash(bDate, in: app)
        } else {
            selectTrashTestFilter("Trash", in: app)
            assertTrashTestEmpty(in: app)
            attachTrashScreenshot(app, "VAL-TRASH-027", "30-days-plus-one-second-empty-trash")
            selectTrashTestFilter("Archived", in: app)
            assertTrashTestEmpty(in: app)
            selectTrashTestFilter("Active", in: app)
            assertTrashRelaunchMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001"])
            attachTrashScreenshot(app, "VAL-TRASH-027", "30-days-plus-one-second-only-002-active")
        }
        try assertTrashTestPurgeOnDisk(roots, projectID: "ui-project-001")
        XCTAssertEqual(try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-002"), bBytes)
        if let cBytes {
            XCTAssertEqual(try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-003"), cBytes)
        }
        try attachTrashTestListing(roots, "VAL-TRASH-027", "\(expiryInterval)-seconds-expired-only-purge")
    }

    private func launchTrashRelaunchApp(
        token: String, keepRoot: Bool = false, clock: Int, valID: String
    ) -> XCUIApplication {
        let app = launchIsolatedApp(rootToken: token, keepRoot: keepRoot, extraArguments: [
            "--trash-clock=\(clock)", "-AppleLocale", "en_US", "-AppleLanguages", "(en)",
        ])
        let arguments = app.launchArguments.joined(separator: " ")
        print("\(valID) launch arguments: \(arguments)")
        attachTrashText(valID, "launch-clock-\(clock)-keep-\(keepRoot)", arguments)
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 10))
        return app
    }

    private func openTrashRelaunchLibrary(in app: XCUIApplication) {
        let library = app.buttons["home.existingRooms"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.press(forDuration: 0.15)
        XCTAssertTrue(app.buttons["library.showTrash"].waitForExistence(timeout: 10))
    }

    private func assertTrashRelaunchMembershipAndDate(_ purgeDate: String, in app: XCUIApplication) {
        selectTrashTestFilter("Active", in: app)
        assertTrashRelaunchMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001"])
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestEmpty(in: app)
        selectTrashTestFilter("Trash", in: app)
        assertTrashRelaunchMembership(in: app, present: ["ui-project-001"], absent: ["ui-project-002"])
        XCTAssertEqual(trashTestPurgeLabel("ui-project-001", in: app), purgeDate)
    }

    private func assertTrashRelaunchOnlyRecentTrash(_ purgeDate: String, in app: XCUIApplication) {
        selectTrashTestFilter("Trash", in: app)
        assertTrashRelaunchMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001", "ui-project-003"])
        XCTAssertEqual(trashTestPurgeLabel("ui-project-002", in: app), purgeDate)
        attachTrashScreenshot(app, "VAL-TRASH-027", "recent-B-only-trash-identical-purge-date")
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestEmpty(in: app)
        selectTrashTestFilter("Active", in: app)
        assertTrashRelaunchMembership(in: app, present: ["ui-project-003"], absent: ["ui-project-001", "ui-project-002"])
        attachTrashScreenshot(app, "VAL-TRASH-027", "active-C-only-after-expired-A-purge")
    }

    private func assertTrashRelaunchHomePurge(_ roots: TrashTestRoots, in app: XCUIApplication, slug: String) throws {
        let directories = ["Projects", "RedesignState", "ConceptSets"].map {
            roots.root($0).appendingPathComponent("ui-project-001")
        }
        for directory in directories { try requireTrashTestSafePath(directory, under: roots.temporary) }
        let purged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [purged], timeout: 10), .completed,
                       "Home must purge expired package and seeded companions without a library tap or refresh.")
        XCTAssertTrue(app.buttons["home.existingRooms"].exists)
        XCTAssertFalse(app.buttons["library.showTrash"].exists)
        attachTrashScreenshot(app, "VAL-TRASH-027", slug)
    }

    private func trashRelaunchMetadata(
        _ roots: TrashTestRoots, projectID: String, valID: String
    ) throws -> [String: Any] {
        let file = roots.root("Projects").appendingPathComponent(projectID).appendingPathComponent("metadata.json")
        try requireTrashTestSafePath(file, under: roots.temporary)
        let bytes = try Data(contentsOf: file)
        attachTrashText(valID, "\(projectID)-metadata-json", try XCTUnwrap(String(data: bytes, encoding: .utf8)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func removeTrashRelaunchIndex(in roots: TrashTestRoots) throws {
        let support = roots.temporary.deletingLastPathComponent()
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let name = "RoomScanStudioIndex.store"
        let store = support.appendingPathComponent(name)
        try requireTrashTestSafePath(store, under: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path),
                      "Positive control: the named SwiftData store must exist before deletion.")
        var removed: [String] = []
        for suffix in ["", "-wal", "-shm"] {
            let file = support.appendingPathComponent(name + suffix)
            try requireTrashTestSafePath(file, under: support)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            try FileManager.default.removeItem(at: file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            removed.append(file.lastPathComponent)
        }
        XCTAssertTrue(removed.contains(name))
        attachTrashText("VAL-TRASH-016", "stopped-app-index-files-deleted",
                        "Deleted disposable local index files: \(removed.joined(separator: ", ")). Packages untouched.")
    }
}
