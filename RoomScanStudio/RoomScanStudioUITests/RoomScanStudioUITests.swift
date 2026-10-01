import CryptoKit
import UIKit
import XCTest

final class RoomScanStudioUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Retain bounded app-only failure evidence even when the CLI disables
        // Xcode's much larger automatic simulator diagnostic collection.
        guard let run = testRun, run.failureCount > 0 else { return }
        let app = XCUIApplication()
        guard app.state == .runningForeground else { return }
        let hierarchy = XCTAttachment(string: String(app.debugDescription.prefix(50_000)))
        hierarchy.name = "failed-ui-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "failed-ui-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHomeShowsBothPrimaryActions() {
        let app = launchIsolatedApp()

        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["home.newRoomScan"].exists)
    }

    func testAccessibilityDynamicTypeKeepsPrimaryAndMockReviewActionsHittable() {
        let app = launchAccessibilityIsolatedApp()
        let existingRooms = app.buttons["home.existingRooms"]
        let newRoomScan = app.buttons["home.newRoomScan"]
        scrollIntoView(existingRooms, in: app)
        XCTAssertTrue(existingRooms.waitForExistence(timeout: 5))
        XCTAssertTrue(existingRooms.isHittable)
        scrollIntoView(newRoomScan, in: app)
        XCTAssertTrue(newRoomScan.waitForExistence(timeout: 5))
        XCTAssertTrue(newRoomScan.isHittable)

        newRoomScan.tap()
        let mockReview = app.buttons["newScan.openMockReview"]
        scrollIntoView(mockReview, in: app)
        XCTAssertTrue(mockReview.waitForExistence(timeout: 5))
        XCTAssertTrue(mockReview.isHittable)
        mockReview.tap()

        XCTAssertTrue(app.staticTexts["mockReview.title"].waitForExistence(timeout: 5))
        let save = app.buttons["mockReview.save"]
        let discard = app.buttons["mockReview.discard"]
        scrollIntoView(save, in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        scrollIntoView(discard, in: app)
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        XCTAssertTrue(discard.isHittable)
    }

    func testEmptyLibraryUsesIsolatedResetStore() {
        let app = launchIsolatedApp()
        app.buttons["home.existingRooms"].tap()

        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 2))
    }

    func testIsolatedTokenKeepsSavedRoomAcrossRelaunchAndResetStartsEmpty() {
        executionTimeAllowance = 180
        let token = String(UUID().uuidString.prefix(12))
        let first = launchIsolatedApp(rootToken: token)
        saveMockRoom(in: first)
        first.terminate()

        let kept = launchIsolatedApp(rootToken: token, keepRoot: true)
        XCTAssertTrue(kept.buttons["home.existingRooms"].waitForExistence(timeout: 10))
        kept.buttons["home.existingRooms"].tap()
        XCTAssertTrue(kept.buttons["library.showActive"].waitForExistence(timeout: 10))
        kept.buttons["library.showActive"].tap()
        XCTAssertTrue(kept.buttons["library.project.ui-project-001"].waitForExistence(timeout: 10))
        let persisted = XCTAttachment(screenshot: kept.screenshot())
        persisted.name = "VAL-TRASH-014-saved-room-after-token-relaunch"
        persisted.lifetime = .keepAlways
        add(persisted)
        kept.terminate()

        let reset = launchIsolatedApp(rootToken: token)
        XCTAssertTrue(reset.buttons["home.existingRooms"].waitForExistence(timeout: 10))
        reset.buttons["home.existingRooms"].tap()
        XCTAssertTrue(reset.staticTexts["library.empty"].waitForExistence(timeout: 10))
        XCTAssertFalse(reset.buttons["library.project.ui-project-001"].exists)
        let empty = XCTAttachment(screenshot: reset.screenshot())
        empty.name = "VAL-TRASH-014-token-relaunch-without-keep-is-empty"
        empty.lifetime = .keepAlways
        add(empty)
        reset.terminate()
    }

    func testExplicitMockReviewDoesNotAutoSeedLibrary() {
        let app = launchIsolatedApp()
        app.buttons["home.newRoomScan"].tap()
        app.buttons["newScan.openMockReview"].tap()

        XCTAssertTrue(app.staticTexts["mockReview.title"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["mockReview.roomName"].exists)
        XCTAssertTrue(app.textFields["mockReview.manualLocation"].exists)
    }

    func testMockSaveCreatesOneProfileAndDiscardCreatesNone() {
        executionTimeAllowance = 120
        let app = launchIsolatedApp()

        openMockReview(in: app)
        app.buttons["mockReview.discard"].tap()
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 2))
        app.buttons["home.existingRooms"].tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 2))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        openMockReview(in: app)
        app.buttons["mockReview.save"].tap()
        XCTAssertTrue(app.buttons["mockReview.openLibrary"].waitForExistence(timeout: 5))
        app.buttons["mockReview.openLibrary"].tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5))
    }

    func testMetadataDuplicateArchiveAndUnarchiveRemainExplicit() {
        executionTimeAllowance = 240
        let app = launchIsolatedApp()
        saveMockRoom(in: app)

        openTrashTestProject("ui-project-001", in: app)
        openTrashTestInfo(in: app)
        XCTAssertTrue(app.buttons["detail.editMetadata"].waitForExistence(timeout: 10))
        app.buttons["detail.editMetadata"].tap()
        XCTAssertTrue(app.textFields["metadata.roomName"].waitForExistence(timeout: 10))
        app.textFields["metadata.roomName"].tap()
        app.textFields["metadata.roomName"].typeText(" Updated")
        app.buttons["metadata.save"].tap()
        let updatedRoomName = app.staticTexts["detail.roomName"]
        XCTAssertTrue(updatedRoomName.waitForExistence(timeout: 10))
        XCTAssertTrue(updatedRoomName.label.contains("Updated"))

        tapTrashTestDetailAction("detail.duplicate", in: app)
        backToTrashTestLibrary(in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001", "ui-project-002"])
        attachTrashScreenshot(app, "VAL-TRASH-026", "legacy-metadata-and-duplicate-successor")

        openTrashTestProject("ui-project-001", in: app)
        setTrashTestArchived(true, in: app)
        backToTrashTestLibrary(in: app)
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001"], absent: ["ui-project-002"])
        attachTrashScreenshot(app, "VAL-TRASH-024", "legacy-archive-successor")
        openTrashTestProject("ui-project-001", in: app)
        setTrashTestArchived(false, in: app)
        openTrashTestInfo(in: app)
        XCTAssertTrue(app.buttons["detail.archive"].waitForExistence(timeout: 10))
        closeTrashTestInfo(in: app)
        backToTrashTestLibrary(in: app)
        selectTrashTestFilter("Active", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001", "ui-project-002"])
        attachTrashScreenshot(app, "VAL-TRASH-026", "legacy-unarchive-successor")
    }

    func testTrashLifecycleConfirmationRestoreArchiveAndDeleteNowPreserveOtherProject() throws {
        executionTimeAllowance = 600
        let token = String(UUID().uuidString.prefix(12))
        // A real clock gives the two saves distinct lastRevisedDate values.
        // The separate forced-clock test verifies the exact retention date.
        let app = launchIsolatedApp(rootToken: token)
        defer { app.terminate() }
        saveTrashTestRooms(2, in: app)
        assertTrashTestOrder(["ui-project-002", "ui-project-001"], in: app)
        attachTrashScreenshot(app, "VAL-TRASH-018", "two-active-projects")
        attachTrashScreenshot(app, "VAL-TRASH-023", "original-newest-first-order")
        // Prove the filter row is reachable from Home by ordinary taps, not
        // solely through the post-save Open library shortcut.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 10))
        app.buttons["home.existingRooms"].tap()
        assertTrashTestFilterTargets(in: app)
        selectTrashTestFilter("Trash", in: app)
        assertTrashTestEmpty(in: app)
        let emptyCopy = app.staticTexts["library.empty"].label
        XCTAssertTrue(emptyCopy.localizedCaseInsensitiveContains("Trash"))
        XCTAssertTrue(emptyCopy.contains("30"))
        XCTAssertFalse(emptyCopy.localizedCaseInsensitiveContains("erased"))
        attachTrashScreenshot(app, "VAL-TRASH-019", "tap-only-empty-trash-30-day-copy")
        selectTrashTestFilter("Active", in: app)

        // Persist real revision-bound redesign documents through the app UI,
        // then add marker-owned on-disk Concept Set cleanup fixtures. The
        // screen-only --slice3-ui-fixture does not persist project companions.
        for id in ["ui-project-001", "ui-project-002"] {
            openTrashTestProject(id, in: app)
            seedTrashTestRedesignThroughUI(in: app)
            backToTrashTestLibrary(in: app)
        }
        let roots = try trashTestRoots(token: token)
        if let roots {
            try seedTrashTestOwnedConcept(in: roots, projectID: "ui-project-001", token: token)
            try seedTrashTestOwnedConcept(in: roots, projectID: "ui-project-002", token: token)
            try attachTrashTestListing(roots, "VAL-TRASH-025", "seeded-companions-before-lifecycle")
        }
        let firstCompanions = try roots.map { try trashTestCompanionBytes($0, projectID: "ui-project-001") }
        let firstPackage = try roots.map {
            try trashTestBytes($0.root("Projects").appendingPathComponent("ui-project-001"), under: $0.temporary)
        }
        let otherBytes = try roots.map { try trashTestProjectAndCompanionBytes($0, projectID: "ui-project-002") }

        openTrashTestProject("ui-project-001", in: app)
        let headBefore = trashTestHead(in: app)
        XCTAssertFalse(app.buttons["detail.delete"].exists, "Active rooms must offer Trash, not Delete now.")
        tapTrashTestDetailAction("detail.trash", in: app)
        let confirmation = trashTestConfirmation("trash.confirm", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "30 days")).firstMatch.exists)
        attachTrashScreenshot(app, "VAL-TRASH-020", "move-to-trash-confirmation-30-days")
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 10))
        backToTrashTestLibrary(in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001", "ui-project-002"])
        attachTrashScreenshot(app, "VAL-TRASH-020", "cancel-keeps-active-project")

        openTrashTestProject("ui-project-001", in: app)
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-020", slug: "confirmed-trash")
        assertTrashTestMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001"])
        attachTrashScreenshot(app, "VAL-TRASH-020", "active-excludes-trashed-project")
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestEmpty(in: app)
        XCTAssertFalse(app.buttons["library.project.ui-project-001"].exists)
        attachTrashScreenshot(app, "VAL-TRASH-020", "archived-excludes-trashed-project")
        selectTrashTestFilter("Trash", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001"], absent: ["ui-project-002"])
        let purgeLabel = trashTestPurgeLabel("ui-project-001", in: app)
        assertTrashTestBadge("TRASH", projectID: "ui-project-001", in: app)
        assertTrashTestNoBadge("ARCHIVED", projectID: "ui-project-001", in: app)
        attachTrashScreenshot(app, "VAL-TRASH-020", "confirmed-trash-filter")
        attachTrashScreenshot(app, "VAL-TRASH-018", "one-trash-one-active")
        attachTrashScreenshot(app, "VAL-TRASH-021", "trash-badge-and-purge-line")

        openTrashTestProject("ui-project-001", in: app)
        assertTrashTestReadOnlyDetail(in: app, purgeLabel: purgeLabel)
        tapTrashTestDetailAction("detail.restore", in: app)
        assertTrashTestEmpty(in: app) // Restore preserves the selected Trash filter.
        attachTrashScreenshot(app, "VAL-TRASH-023", "restore-dismisses-to-empty-trash")
        selectTrashTestFilter("Active", in: app)
        assertTrashTestOrder(["ui-project-002", "ui-project-001"], in: app)
        attachTrashScreenshot(app, "VAL-TRASH-023", "restored-original-sort-position")
        attachTrashScreenshot(app, "VAL-TRASH-018", "both-active-after-restore")
        if let roots, let firstCompanions {
            XCTAssertEqual(try trashTestCompanionBytes(roots, projectID: "ui-project-001"), firstCompanions)
            if let firstPackage {
                let restored = try trashTestBytes(
                    roots.root("Projects").appendingPathComponent("ui-project-001"), under: roots.temporary
                )
                XCTAssertEqual(restored.filter { $0.key != "metadata.json" },
                               firstPackage.filter { $0.key != "metadata.json" },
                               "Restore must preserve every immutable revision, asset and manifest byte.")
                let oldMetadata = try JSONSerialization.jsonObject(with: XCTUnwrap(firstPackage["metadata.json"])) as? NSDictionary
                let restoredMetadata = try JSONSerialization.jsonObject(with: XCTUnwrap(restored["metadata.json"])) as? NSDictionary
                XCTAssertEqual(restoredMetadata?["lastRevisedDate"] as? String, oldMetadata?["lastRevisedDate"] as? String)
                XCTAssertTrue(restoredMetadata?["trashedAt"] == nil || restoredMetadata?["trashedAt"] is NSNull)
            }
            try attachTrashTestListing(roots, "VAL-TRASH-023", "restore-keeps-seeded-companion-bytes")
        }
        openTrashTestProject("ui-project-001", in: app)
        XCTAssertFalse(identifiedElement("detail.trashBanner", in: app).exists)
        XCTAssertTrue(app.buttons["detail.editRoom"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["detail.rescan"].waitForExistence(timeout: 10))
        XCTAssertEqual(trashTestHead(in: app), headBefore)
        XCTAssertTrue(app.buttons["detail.trash"].waitForExistence(timeout: 10))
        attachTrashScreenshot(app, "VAL-TRASH-023", "restored-head-and-mutation-controls")

        setTrashTestArchived(true, in: app)
        backToTrashTestLibrary(in: app)
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001"], absent: ["ui-project-002"])
        attachTrashScreenshot(app, "VAL-TRASH-024", "archived-before-trash")
        openTrashTestProject("ui-project-001", in: app)
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-024", slug: "archive-then-trash")
        assertTrashTestEmpty(in: app)
        attachTrashScreenshot(app, "VAL-TRASH-024", "archived-excludes-archived-trash")
        selectTrashTestFilter("Active", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001"])
        attachTrashScreenshot(app, "VAL-TRASH-024", "active-excludes-archived-trash")
        selectTrashTestFilter("Trash", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001"])
        assertTrashTestBadge("TRASH", projectID: "ui-project-001", in: app)
        assertTrashTestBadge("ARCHIVED", projectID: "ui-project-001", in: app)
        _ = trashTestPurgeLabel("ui-project-001", in: app)
        attachTrashScreenshot(app, "VAL-TRASH-024", "archived-trash-badges")
        openTrashTestProject("ui-project-001", in: app)
        tapTrashTestDetailAction("detail.restore", in: app)
        assertTrashTestEmpty(in: app)
        attachTrashScreenshot(app, "VAL-TRASH-024", "archived-restore-clears-trash")
        selectTrashTestFilter("Active", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001"])
        attachTrashScreenshot(app, "VAL-TRASH-024", "archived-restore-not-active")
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-001"], absent: ["ui-project-002"])
        attachTrashScreenshot(app, "VAL-TRASH-024", "restore-preserves-archived-flag")

        openTrashTestProject("ui-project-001", in: app)
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-026", slug: "second-trash-before-delete")
        selectTrashTestFilter("Trash", in: app)
        openTrashTestProject("ui-project-001", in: app)
        confirmTrashTestDeleteWithBackupDisabled(in: app, slug: "default-off")
        assertTrashTestEmpty(in: app)
        attachTrashScreenshot(app, "VAL-TRASH-025", "default-off-empty-trash-after-delete")
        attachTrashScreenshot(app, "VAL-TRASH-026", "single-process-lifecycle-final-empty-trash")
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestEmpty(in: app)
        attachTrashScreenshot(app, "VAL-TRASH-025", "default-off-empty-archived-after-delete")
        selectTrashTestFilter("Active", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001"])
        attachTrashScreenshot(app, "VAL-TRASH-018", "only-other-project-after-delete")
        if let roots, let otherBytes {
            try assertTrashTestPurgeOnDisk(roots, projectID: "ui-project-001")
            XCTAssertEqual(try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-002"), otherBytes)
            try attachTrashTestListing(roots, "VAL-TRASH-025", "default-off-purged-companions-other-project-unchanged")
        }
    }

    func testTrashForcedClockRendersExactlyThirtyDayPurgeDate() {
        executionTimeAllowance = 180
        let app = launchIsolatedApp(
            rootToken: String(UUID().uuidString.prefix(12)),
            extraArguments: ["--trash-clock=1800014400", "-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
        )
        defer { app.terminate() }
        saveMockRoom(in: app)
        openTrashTestProject("ui-project-001", in: app)
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-013", slug: "forced-clock-confirmation")
        selectTrashTestFilter("Trash", in: app)
        let label = trashTestPurgeLabel("ui-project-001", in: app)
        let expected = Date(timeIntervalSince1970: 1_800_014_400 + 2_592_000)
            .formatted(.dateTime.year().month().day().locale(Locale(identifier: "en_US")))
        XCTAssertEqual(label, "Deletes permanently on \(expected)")
        assertTrashTestBadge("TRASH", projectID: "ui-project-001", in: app)
        assertTrashTestNoBadge("ARCHIVED", projectID: "ui-project-001", in: app)
        attachTrashText("VAL-TRASH-013", "forced-clock-date-comparison",
                        "trash-clock=1800014400; retention=2592000; expected=\(expected); actual=\(label)")
        attachTrashScreenshot(app, "VAL-TRASH-013", "forced-february-14-2027-purge-date")
        attachTrashScreenshot(app, "VAL-TRASH-021", "forced-date-trash-badge")
    }

    func testTrashOrderingUsesTrashDateNotProjectIDOrLastRevision() {
        executionTimeAllowance = 300
        // Deliberately do not freeze the clock: 002,001,003 must have distinct
        // trash timestamps rather than fall into the project-ID tie breaker.
        let app = launchIsolatedApp(rootToken: String(UUID().uuidString.prefix(12)))
        defer { app.terminate() }
        saveTrashTestRooms(3, in: app)
        for id in ["ui-project-002", "ui-project-001", "ui-project-003"] {
            openTrashTestProject(id, in: app)
            moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-017", slug: "trash-\(id)")
            XCTAssertFalse(app.buttons["library.project.\(id)"].exists)
        }
        assertTrashTestEmpty(in: app)
        attachTrashScreenshot(app, "VAL-TRASH-017", "all-three-excluded-from-active")
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestEmpty(in: app)
        attachTrashScreenshot(app, "VAL-TRASH-017", "all-three-excluded-from-archived")
        selectTrashTestFilter("Trash", in: app)
        assertTrashTestOrder(["ui-project-002", "ui-project-001", "ui-project-003"], in: app)
        let libraryScroll = app.scrollViews.firstMatch
        assertTrashTestFullyVisible(app.buttons["library.project.ui-project-003"], in: libraryScroll)
        let visible = libraryScroll.frame.intersection(app.windows.firstMatch.frame)
        for id in ["ui-project-002", "ui-project-001", "ui-project-003"] {
            XCTAssertTrue(visible.contains(app.buttons["library.project.\(id)"].frame),
                          "The retained order screenshot must show all three rows.")
        }
        attachTrashScreenshot(app, "VAL-TRASH-017", "ascending-trash-date-002-001-003")
    }

    func testTrashDeleteNowWithFakeBackupExplicitlyTurnedOffHasOneChoiceAndNoJournal() throws {
        executionTimeAllowance = 360
        let token = String(UUID().uuidString.prefix(12))
        let app = launchIsolatedApp(rootToken: token, extraArguments: ["--use-fake-cloud-backup"])
        defer { app.terminate() }
        saveTrashTestRooms(2, in: app)
        for id in ["ui-project-001", "ui-project-002"] {
            openTrashTestProject(id, in: app)
            seedTrashTestRedesignThroughUI(in: app)
            backToTrashTestLibrary(in: app)
        }
        let roots = try trashTestRoots(token: token)
        if let roots {
            try seedTrashTestOwnedConcept(in: roots, projectID: "ui-project-001", token: token)
            try seedTrashTestOwnedConcept(in: roots, projectID: "ui-project-002", token: token)
            try attachTrashTestListing(roots, "VAL-TRASH-025", "fake-backup-off-seeded-before-delete")
        }
        let otherBytes = try roots.map { try trashTestProjectAndCompanionBytes($0, projectID: "ui-project-002") }
        openTrashTestProject("ui-project-001", in: app)
        openTrashTestInfo(in: app)
        let backup = app.buttons["detail.backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        scrollIntoView(backup, in: app.scrollViews["detail.infoPanel.scroll"])
        backup.tap()
        XCTAssertTrue(app.scrollViews["cloudBackup.scroll"].waitForExistence(timeout: 10))
        let enable = app.switches["cloudBackup.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        scrollIntoView(enable, in: app.scrollViews["cloudBackup.scroll"])
        XCTAssertEqual(enable.value as? String, "1", "The fake flag enables backup at launch.")
        enable.tap() // Exactly once: ON -> OFF, never an attempt to enable the fake.
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: enable)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 10), .completed)
        attachTrashScreenshot(app, "VAL-TRASH-025", "fake-backup-toggle-explicitly-off")
        XCTAssertTrue(app.buttons["cloudBackup.close"].waitForExistence(timeout: 10))
        app.buttons["cloudBackup.close"].tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 10))
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-025", slug: "fake-backup-off-trash")
        selectTrashTestFilter("Trash", in: app)
        openTrashTestProject("ui-project-001", in: app)
        confirmTrashTestDeleteWithBackupDisabled(in: app, slug: "fake-explicitly-off")
        assertTrashTestEmpty(in: app)
        attachTrashScreenshot(app, "VAL-TRASH-025", "fake-backup-off-empty-trash")
        selectTrashTestFilter("Archived", in: app)
        assertTrashTestEmpty(in: app)
        selectTrashTestFilter("Active", in: app)
        assertTrashTestMembership(in: app, present: ["ui-project-002"], absent: ["ui-project-001"])
        attachTrashScreenshot(app, "VAL-TRASH-025", "fake-backup-off-other-project-retained")
        if let roots, let otherBytes {
            try assertTrashTestPurgeOnDisk(roots, projectID: "ui-project-001")
            XCTAssertEqual(try trashTestProjectAndCompanionBytes(roots, projectID: "ui-project-002"), otherBytes)
            try attachTrashTestListing(roots, "VAL-TRASH-025", "fake-backup-off-purged-no-journal-other-bytes-unchanged")
        }
    }

    func testTrashAccessibilityXXXLKeepsFiltersRowsBannerAndActionsReachableInOrder() {
        executionTimeAllowance = 480
        let app = launchIsolatedApp(extraArguments: [
            "--trash-clock=1800014400",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        defer { app.terminate() }
        saveMockRoom(in: app)
        assertTrashTestFilterTargets(in: app, valID: "VAL-TRASH-029")
        openTrashTestProject("ui-project-001", in: app)
        moveTrashTestProjectToTrash(in: app, valID: "VAL-TRASH-029", slug: "axxxl-confirmation")
        selectTrashTestFilter("Trash", in: app)
        let row = app.buttons["library.project.ui-project-001"]
        scrollIntoView(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        let purge = app.staticTexts["library.project.ui-project-001.purgeDate"]
        XCTAssertTrue(purge.waitForExistence(timeout: 10))
        scrollIntoView(purge, in: app)
        assertTrashTestFullyVisible(purge, in: app.scrollViews.firstMatch)
        XCTAssertFalse(purge.label.contains("…"))
        XCTAssertFalse(purge.label.contains("..."))
        attachTrashScreenshot(app, "VAL-TRASH-029", "axxxl-row-full-purge-date")
        openTrashTestProject("ui-project-001", in: app)
        let banner = identifiedElement("detail.trashBanner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        scrollIntoView(banner, in: app.scrollViews["detail.scroll"], direction: .backward)
        assertTrashTestFullyVisible(banner, in: app.scrollViews["detail.scroll"])
        XCTAssertFalse(banner.label.contains("…"))
        attachTrashScreenshot(app, "VAL-TRASH-029", "axxxl-full-trash-banner")
        for id in ["detail.restore", "detail.delete"] {
            let action = app.buttons[id]
            XCTAssertTrue(action.waitForExistence(timeout: 10))
            scrollIntoView(action, in: app.scrollViews["detail.scroll"])
            assertTrashTestTarget(action)
            assertTrashTestFullyVisible(action, in: app.scrollViews["detail.scroll"])
            attachTrashScreenshot(app, "VAL-TRASH-029", "axxxl-\(id)")
        }
        let order = app.descendants(matching: .any).allElementsBoundByAccessibilityElement
            .map(\.identifier).filter { ["detail.trashBanner", "detail.restore", "detail.delete"].contains($0) }
        XCTAssertEqual(order, ["detail.trashBanner", "detail.restore", "detail.delete"])
        attachTrashText("VAL-TRASH-029", "accessibility-order-and-frames",
                        "order=\(order)\n\(trashTestElementInventory(in: app))")
    }

    func testTrashDarkModeAndIncreaseContrastKeepListOrderAndDetailLegible() throws {
        executionTimeAllowance = 300
        let token = String(UUID().uuidString.prefix(12))
        let light = launchIsolatedApp(rootToken: token, extraArguments: ["-AppleInterfaceStyle", "Light"])
        saveTrashTestRooms(2, in: light)
        for id in ["ui-project-002", "ui-project-001"] {
            openTrashTestProject(id, in: light)
            moveTrashTestProjectToTrash(in: light, valID: "VAL-TRASH-030", slug: "light-trash-\(id)")
        }
        selectTrashTestFilter("Trash", in: light)
        assertTrashTestOrder(["ui-project-002", "ui-project-001"], in: light)
        XCTAssertGreaterThan(try trashTestPaperBrightness(in: light), 0.7,
                             "The light control must actually render light paper.")
        attachTrashScreenshot(light, "VAL-TRASH-030", "light-order-control")
        light.terminate()

        // UIAccessibility's real system setting, not an invented app flag.
        // The Simulator verification operator enables Increase Contrast before
        // running this test; the assertion fails rather than mislabeling evidence.
        let dark = launchIsolatedApp(rootToken: token, keepRoot: true, extraArguments: [
            "-AppleInterfaceStyle", "Dark",
        ])
        defer { dark.terminate() }
        XCTAssertTrue(UIAccessibility.isDarkerSystemColorsEnabled,
                      "Enable Simulator Increase Contrast before collecting VAL-TRASH-030 evidence.")
        XCTAssertTrue(dark.buttons["home.existingRooms"].waitForExistence(timeout: 10))
        dark.buttons["home.existingRooms"].tap()
        selectTrashTestFilter("Trash", in: dark)
        assertTrashTestOrder(["ui-project-002", "ui-project-001"], in: dark)
        XCTAssertLessThan(try trashTestPaperBrightness(in: dark), 0.3,
                          "Dark evidence must render dark paper, not just carry a Dark launch argument.")
        for id in ["ui-project-002", "ui-project-001"] {
            assertTrashTestBadge("TRASH", projectID: id, in: dark)
            _ = trashTestPurgeLabel(id, in: dark)
        }
        attachTrashScreenshot(dark, "VAL-TRASH-030", "dark-increase-contrast-trash-list")
        openTrashTestProject("ui-project-001", in: dark)
        let banner = identifiedElement("detail.trashBanner", in: dark)
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        scrollIntoView(banner, in: dark.scrollViews["detail.scroll"], direction: .backward)
        assertTrashTestFullyVisible(banner, in: dark.scrollViews["detail.scroll"])
        attachTrashScreenshot(dark, "VAL-TRASH-030", "dark-increase-contrast-trash-banner")
        let restore = dark.buttons["detail.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        scrollIntoView(restore, in: dark.scrollViews["detail.scroll"])
        assertTrashTestTarget(restore)
        assertTrashTestTarget(dark.buttons["detail.delete"])
        attachTrashScreenshot(dark, "VAL-TRASH-030", "dark-increase-contrast-restore-delete-actions")
        attachTrashText("VAL-TRASH-030", "system-contrast-and-element-frames",
                        "UIAccessibility.isDarkerSystemColorsEnabled=true\n\(trashTestElementInventory(in: dark))")
    }

    func testRevisionInspectionAndRestoreCreateNewLineage() {
        let app = launchIsolatedApp()
        saveMockRoom(in: app)

        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 5))
        let detailScroll = app.scrollViews["detail.scroll"]
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 5))
        let revisionOne = app.buttons["revision.revision-001"]
        scrollIntoView(revisionOne, in: detailScroll)
        XCTAssertTrue(revisionOne.isHittable)
        revisionOne.tap()
        let revisionInspection = app.staticTexts["revision.inspect.revision-001"]
        XCTAssertTrue(revisionInspection.waitForExistence(timeout: 2))
        let inspectionScroll = app.scrollViews["revision.inspect.scroll"]
        XCTAssertTrue(inspectionScroll.waitForExistence(timeout: 5))
        let restore = app.buttons["revision.restore.revision-001"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        scrollIntoView(restore, in: inspectionScroll)
        XCTAssertTrue(restore.isHittable)
        restore.tap()
        XCTAssertTrue(revisionInspection.waitForNonExistence(timeout: 5))
        let headRevision = app.staticTexts["detail.headRevision"]
        XCTAssertTrue(waitForLabel(headRevision, equals: "revision-002", timeout: 5))
        XCTAssertEqual(headRevision.label, "revision-002")
        let revisionTwo = app.buttons["revision.revision-002"]
        scrollIntoView(revisionTwo, in: detailScroll, direction: .backward)
        XCTAssertTrue(app.buttons["revision.revision-002"].waitForExistence(timeout: 5))
        XCTAssertTrue(revisionTwo.isHittable)
    }

    func testProductionRescanPathIsExplicitlyUnavailable() {
        let app = launchIsolatedApp()
        saveMockRoom(in: app)

        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.buttons["detail.rescan"].waitForExistence(timeout: 5))
        app.buttons["detail.rescan"].tap()
        XCTAssertTrue(app.staticTexts["rescan.unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["rescan.undo"].waitForExistence(timeout: 5))
    }

    func testDeterministicFixtureRescanPreviewUndoAcceptAndRevert() {
        let app = launchRescanFixtureApp()
        saveMockRoom(in: app)

        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 5))
        let detailScroll = app.scrollViews["detail.scroll"]
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 5))
        let detailRescan = app.buttons["detail.rescan"]
        XCTAssertTrue(detailRescan.waitForExistence(timeout: 5))
        XCTAssertTrue(detailRescan.isHittable)
        detailRescan.tap()
        XCTAssertTrue(app.staticTexts["rescan.preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["rescan.status"].waitForExistence(timeout: 5))
        let undo = app.buttons["rescan.undo"]
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["detail.headRevision"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.headRevision"].label, "revision-001")
        XCTAssertTrue(detailRescan.isHittable)

        detailRescan.tap()
        XCTAssertTrue(app.staticTexts["rescan.preview"].waitForExistence(timeout: 5))
        let accept = app.buttons["rescan.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(app.staticTexts["rescan.accepted"].waitForExistence(timeout: 5))
        let done = app.buttons["rescan.done"]
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        let headRevision = app.staticTexts["detail.headRevision"]
        XCTAssertTrue(waitForLabel(headRevision, equals: "revision-002", timeout: 5))
        let revisionTwo = app.buttons["revision.revision-002"]
        scrollIntoView(revisionTwo, in: detailScroll)
        XCTAssertTrue(revisionTwo.isHittable)

        let revisionOne = app.buttons["revision.revision-001"]
        scrollIntoView(revisionOne, in: detailScroll)
        XCTAssertTrue(revisionOne.isHittable)
        revisionOne.tap()
        let revisionInspection = app.staticTexts["revision.inspect.revision-001"]
        XCTAssertTrue(revisionInspection.waitForExistence(timeout: 5))
        let inspectionScroll = app.scrollViews["revision.inspect.scroll"]
        XCTAssertTrue(inspectionScroll.waitForExistence(timeout: 5))
        let restore = app.buttons["revision.restore.revision-001"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        scrollIntoView(restore, in: inspectionScroll)
        XCTAssertTrue(restore.isHittable)
        restore.tap()
        XCTAssertTrue(waitForLabel(headRevision, equals: "revision-003", timeout: 5))
        scrollIntoView(detailRescan, in: detailScroll, direction: .backward)
        XCTAssertTrue(detailRescan.isHittable)
        let revisionThree = app.buttons["revision.revision-003"]
        scrollIntoView(revisionThree, in: detailScroll, direction: .backward)
        XCTAssertTrue(revisionThree.isHittable)
    }

    func testFixtureViewerShowsNonARCameraAndVisibilityControls() {
        let app = launchIsolatedApp()
        saveMockRoom(in: app)

        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.buttons["detail.view"].waitForExistence(timeout: 5))
        app.buttons["detail.view"].tap()
        XCTAssertTrue(app.staticTexts["viewer.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["viewer.orbit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["viewer.firstPerson"].waitForExistence(timeout: 5))
        app.buttons["viewer.firstPerson"].tap()
        XCTAssertTrue(app.staticTexts["viewer.noClipDisclosure"].waitForExistence(timeout: 5))

        // Visibility toggles moved into the Layers popover in the full-screen
        // viewer rebuild; they no longer sit inline in the chrome.
        XCTAssertTrue(app.buttons["viewer.layers"].waitForExistence(timeout: 5))
        app.buttons["viewer.layers"].tap()
        XCTAssertTrue(app.switches["viewer.visibility.structural"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["viewer.visibility.objects"].waitForExistence(timeout: 5))
        app.swipeUp() // dismiss the popover before reaching the bottom tray

        // The orbit-only Reset/Top/Front/Side tray only shows in orbit mode.
        app.buttons["viewer.orbit"].tap()
        XCTAssertTrue(app.buttons["viewer.top"].waitForExistence(timeout: 5))
        app.buttons["viewer.top"].tap()
    }

    func testEditorSaveCreatesOneEditAndCancelLeavesHeadUnchanged() {
        let saveApp = launchIsolatedApp()
        saveMockRoom(in: saveApp)
        saveApp.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(saveApp.buttons["detail.editRoom"].waitForExistence(timeout: 5))
        saveApp.buttons["detail.editRoom"].tap()
        XCTAssertTrue(saveApp.staticTexts["editor.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(saveApp.textFields["editor.label"].waitForExistence(timeout: 5))
        saveApp.textFields["editor.label"].tap()
        saveApp.textFields["editor.label"].typeText(" Edited")
        saveApp.buttons["editor.save"].tap()
        XCTAssertTrue(saveApp.staticTexts["detail.headRevision"].waitForExistence(timeout: 5))
        XCTAssertEqual(saveApp.staticTexts["detail.headRevision"].label, "revision-002")
        saveApp.buttons["detail.view"].tap()
        let persistedLabel = saveApp.buttons["viewer.selection.structure-floor-001"]
        XCTAssertTrue(persistedLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(
            persistedLabel.label.contains("Main floor Edited"),
            "The semantic accessibility description must retain the edited captured label."
        )
        saveApp.buttons["viewer.close"].tap()

        let cancelApp = launchIsolatedApp()
        saveMockRoom(in: cancelApp)
        cancelApp.buttons["library.project.ui-project-001"].tap()
        cancelApp.buttons["detail.editRoom"].tap()
        XCTAssertTrue(cancelApp.buttons["editor.cancel"].waitForExistence(timeout: 5))
        cancelApp.buttons["editor.cancel"].tap()
        XCTAssertTrue(cancelApp.staticTexts["detail.headRevision"].waitForExistence(timeout: 5))
        XCTAssertEqual(cancelApp.staticTexts["detail.headRevision"].label, "revision-001")
    }

    func testEditorBlocksInvalidPendingFormInsteadOfSavingAnUnappliedDraft() {
        let app = launchIsolatedApp()
        saveMockRoom(in: app)
        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.buttons["detail.editRoom"].waitForExistence(timeout: 5))
        app.buttons["detail.editRoom"].tap()
        XCTAssertTrue(app.textFields["editor.width"].waitForExistence(timeout: 5))
        app.textFields["editor.width"].tap()
        app.textFields["editor.width"].typeText("not-a-number")
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.staticTexts["editor.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.cancel"].waitForExistence(timeout: 5))
        app.buttons["editor.cancel"].tap()
        XCTAssertTrue(app.staticTexts["detail.headRevision"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.headRevision"].label, "revision-001")
    }

    func testSimulatedCaptureCanPrepareScanReviewAndSaveOneProfile() {
        let app = launchSimulatedCaptureApp()
        openSimulatedCapture(in: app)

        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
        app.buttons["capture.start"].tap()
        XCTAssertTrue(app.buttons["capture.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.referencePhoto"].waitForExistence(timeout: 5))
        app.buttons["capture.referencePhoto"].tap()
        XCTAssertTrue(app.staticTexts["capture.photoReady"].waitForExistence(timeout: 5))
        app.buttons["capture.stop"].tap()
        XCTAssertTrue(app.buttons["capture.save"].waitForExistence(timeout: 5))
        app.buttons["capture.save"].tap()
        XCTAssertTrue(
            app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5)
        )
    }

    func testSlice2CombinedQualityRequiresExplicitSaveAnywayAndPersistsExactReview() {
        executionTimeAllowance = 180
        let app = launchSimulatedCaptureApp(
            extraArguments: ["--simulated-quality", "combined"]
        )
        openSimulatedCapture(in: app)

        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
        app.buttons["capture.start"].tap()
        XCTAssertTrue(app.buttons["capture.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.quality.liveOverlay"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["capture.guidance"].exists)

        app.buttons["capture.stop"].tap()
        let summary = app.descendants(matching: .any)["capture.quality.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["capture.quality.reviewOverlay"].exists)
        for dimension in [
            "Visual sharpness", "Coverage", "AR tracking", "Identification confidence",
        ] {
            XCTAssertTrue(app.staticTexts[dimension].exists)
        }

        let finish = app.buttons["capture.save"]
        scrollIntoView(finish, in: app)
        XCTAssertTrue(finish.isHittable)
        finish.tap()
        let finishGate = app.descendants(matching: .any)["capture.quality.finishGate"]
        XCTAssertTrue(finishGate.waitForExistence(timeout: 5))
        let saveAnyway = app.buttons["capture.quality.saveAnyway"]
        let revisit = app.buttons["capture.quality.revisit"]
        scrollIntoView(saveAnyway, in: app)
        XCTAssertTrue(saveAnyway.isHittable)
        XCTAssertTrue(revisit.exists)
        XCTAssertFalse(app.buttons["library.project.ui-project-001"].exists)

        saveAnyway.tap()
        let project = app.buttons["library.project.ui-project-001"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let persisted = app.descendants(matching: .any)["detail.quality.summary"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 5))
        scrollIntoView(persisted, in: app.scrollViews["detail.scroll"])
        XCTAssertTrue(persisted.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["quality.acknowledged"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["detail.quality.summary"]
                .waitForExistence(timeout: 5)
        )
    }

    func testSlice2QualityScreenshotMatrix() {
        executionTimeAllowance = 600
        let variants: [(name: String, dark: Bool, accessibility: Bool)] = [
            ("light-default", false, false),
            ("dark-default", true, false),
            ("light-accessibility", false, true),
            ("dark-accessibility", true, true),
        ]
        for variant in variants {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-testing", "--reset-local-store", "--use-mock-fixture",
                "--use-simulated-capture", "--simulated-quality", "combined",
                "-AppleInterfaceStyle", variant.dark ? "Dark" : "Light",
            ]
            if variant.accessibility {
                app.launchArguments += [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            }
            app.launch()
            openSimulatedCapture(in: app)

            app.buttons["capture.prepare"].tap()
            XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
            app.buttons["capture.start"].tap()
            let stop = app.buttons["capture.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            XCTAssertTrue(
                app.descendants(matching: .any)["capture.quality.liveOverlay"]
                    .waitForExistence(timeout: 5)
            )
            scrollIntoView(stop, in: app)
            XCTAssertTrue(stop.isHittable)
            attachSlice2Screenshot(app, variant: variant.name, state: "live-coaching-overlay")

            stop.tap()
            let summary = app.descendants(matching: .any)["capture.quality.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 8))
            scrollIntoView(summary, in: app)
            attachSlice2Screenshot(app, variant: variant.name, state: "review-overlay-summary")

            let finish = app.buttons["capture.save"]
            scrollIntoView(finish, in: app)
            XCTAssertTrue(finish.isHittable)
            finish.tap()
            let saveAnyway = app.buttons["capture.quality.saveAnyway"]
            XCTAssertTrue(saveAnyway.waitForExistence(timeout: 5))
            scrollIntoView(saveAnyway, in: app)
            XCTAssertTrue(saveAnyway.isHittable)
            XCTAssertTrue(app.buttons["capture.quality.revisit"].exists)
            attachSlice2Screenshot(app, variant: variant.name, state: "finish-review-save-anyway")

            saveAnyway.tap()
            let project = app.buttons["library.project.ui-project-001"]
            XCTAssertTrue(project.waitForExistence(timeout: 10))
            project.tap()
            let persisted = app.descendants(matching: .any)["detail.quality.summary"]
            XCTAssertTrue(persisted.waitForExistence(timeout: 5))
            scrollIntoView(persisted, in: app.scrollViews["detail.scroll"])
            XCTAssertTrue(persisted.isHittable)
            attachSlice2Screenshot(app, variant: variant.name, state: "reopened-persisted-summary")
            app.terminate()
        }
    }

    func testSlice1OrientationPropertyAndSemanticReviewRemainLocalAndExplicit() {
        executionTimeAllowance = 180
        let app = launchSimulatedCaptureApp()
        openSimulatedCapture(in: app)
        advanceSimulatedCaptureToReview(in: app)
        app.buttons["capture.save"].tap()

        let project = app.buttons["library.project.ui-project-001"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let detailScroll = app.scrollViews["detail.scroll"]
        let review = app.buttons["detail.reviewOrientation"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        scrollIntoView(review, in: detailScroll)
        review.tap()

        XCTAssertTrue(app.descendants(matching: .any)["orientation.planPreview"].waitForExistence(timeout: 5))
        let rotatePlan = app.buttons["orientation.rotatePlan"]
        let mirrorPlan = app.buttons["orientation.mirrorPlan"]
        let resetPlan = app.buttons["orientation.resetPlan"]
        scrollIntoView(rotatePlan, in: app)
        XCTAssertTrue(rotatePlan.exists)
        XCTAssertTrue(mirrorPlan.exists)
        XCTAssertTrue(resetPlan.exists)
        XCTAssertFalse(resetPlan.isEnabled)
        rotatePlan.tap()
        XCTAssertEqual(rotatePlan.value as? String, "90 degrees")
        mirrorPlan.tap()
        XCTAssertEqual(mirrorPlan.value as? String, "On")
        XCTAssertTrue(resetPlan.isEnabled)
        XCTAssertTrue(app.staticTexts["orientation.presentationDisclosure"].exists)
        let suggestionSummary = app.staticTexts["orientation.suggestionSummary"]
        scrollIntoView(suggestionSummary, in: app)
        XCTAssertTrue(app.buttons["orientation.entryFeature"].exists)
        XCTAssertTrue(suggestionSummary.exists)
        XCTAssertTrue(suggestionSummary.label.contains("confidence"))
        XCTAssertFalse(suggestionSummary.label.contains("simulated-door-001"))
        let suggestionDisclosure = app.staticTexts["orientation.suggestionDisclosure"]
        scrollIntoView(suggestionDisclosure, in: app)
        XCTAssertTrue(suggestionDisclosure.exists)
        let save = app.buttons["orientation.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        let request = app.textFields["orientation.request"]
        scrollIntoView(request, in: app)
        XCTAssertTrue(request.exists)
        request.tap()
        request.typeText("Stage this room while preserving the captured shell.")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 10))

        review.tap()
        XCTAssertTrue(app.descendants(matching: .any)["orientation.planPreview"].waitForExistence(timeout: 5))
        let persistedRotatePlan = app.buttons["orientation.rotatePlan"]
        scrollIntoView(persistedRotatePlan, in: app)
        XCTAssertEqual(persistedRotatePlan.value as? String, "90 degrees")
        XCTAssertEqual(app.buttons["orientation.mirrorPlan"].value as? String, "On")
        XCTAssertTrue(app.buttons["orientation.resetPlan"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))

        let property = app.buttons["detail.propertyGrouping"]
        scrollIntoView(property, in: detailScroll)
        property.tap()
        let propertyName = app.textFields["property.name"]
        XCTAssertTrue(propertyName.waitForExistence(timeout: 5))
        propertyName.tap()
        propertyName.typeText("Maple Street")
        app.buttons["property.create"].tap()
        XCTAssertTrue(app.staticTexts["Maple Street"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Independent room projects only"].exists)
        app.buttons["Done"].tap()

        let open = app.buttons["detail.view"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        scrollIntoView(open, in: detailScroll, direction: .backward)
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["viewer.semanticLegend"].waitForExistence(timeout: 5))
        for role in [
            "wall", "door", "window", "opening", "floor", "ceiling",
            "fixedObject", "movableObject", "unknownObject",
        ] {
            XCTAssertTrue(app.descendants(matching: .any)["viewer.legend.\(role)"].exists)
        }
    }

    func testSlice1SemanticScreenshotMatrix() {
        executionTimeAllowance = 300
        let variants: [(name: String, dark: Bool, accessibility: Bool)] = [
            ("light-default", false, false),
            ("dark-default", true, false),
            ("light-accessibility", false, true),
            ("dark-accessibility", true, true),
        ]
        for variant in variants {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-testing", "--reset-local-store", "--use-mock-fixture", "--use-simulated-capture",
                "-AppleInterfaceStyle", variant.dark ? "Dark" : "Light",
            ]
            if variant.accessibility {
                app.launchArguments += [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            }
            app.launch()
            openSimulatedCapture(in: app)
            advanceSimulatedCaptureToReview(in: app)
            app.buttons["capture.save"].tap()
            let project = app.buttons["library.project.ui-project-001"]
            XCTAssertTrue(project.waitForExistence(timeout: 10))
            project.tap()
            let detailScroll = app.scrollViews["detail.scroll"]
            let open = app.buttons["detail.view"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            scrollIntoView(open, in: detailScroll, direction: .backward)
            open.tap()
            XCTAssertTrue(app.descendants(matching: .any)["viewer.semanticLegend"].waitForExistence(timeout: 8))

            let formFactor = app.windows.firstMatch.frame.width >= 600 ? "ipad" : "iphone"
            let screenshot = waitForRenderedViewerScreenshot(in: app)
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "slice1-semantic-\(formFactor)-\(variant.name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func waitForRenderedViewerScreenshot(in app: XCUIApplication) -> XCUIScreenshot {
        let deadline = Date().addingTimeInterval(8)
        var screenshot = XCUIScreen.main.screenshot()
        while !viewerSceneHasRendered(screenshot.image), Date() < deadline {
            _ = app.buttons["viewer.orbit"].waitForExistence(timeout: 0.25)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            screenshot = XCUIScreen.main.screenshot()
        }
        XCTAssertTrue(
            viewerSceneHasRendered(screenshot.image),
            "The semantic screenshot must contain a rendered room, not a blank transition frame."
        )
        return screenshot
    }

    private func attachSlice2Screenshot(
        _ app: XCUIApplication,
        variant: String,
        state: String
    ) {
        let formFactor = app.windows.firstMatch.frame.width >= 600 ? "ipad" : "iphone"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "slice2-quality-\(formFactor)-\(variant)-\(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func viewerSceneHasRendered(_ image: UIImage) -> Bool {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = image.cgImage else {
            return false
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var renderedSamples = 0
        for y in 8..<23 {
            for x in 2..<30 {
                let offset = (y * width + x) * 4
                if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > 32 {
                    renderedSamples += 1
                }
            }
        }
        return renderedSamples >= 80
    }

    func testSimulatedCaptureDiscardCreatesNoProfile() {
        let app = launchSimulatedCaptureApp()
        openSimulatedCapture(in: app)

        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
        app.buttons["capture.discard"].tap()
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 5))
        app.buttons["home.existingRooms"].tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
    }

    func testSimulatedCameraDenialDoesNotCreateAProfile() {
        let app = launchSimulatedCaptureApp(extraArguments: ["--simulated-camera-denied"])
        openSimulatedCapture(in: app)

        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.staticTexts["capture.cameraDenied"].waitForExistence(timeout: 5))
        app.buttons["capture.discard"].tap()
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 5))
        app.buttons["home.existingRooms"].tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
    }

    func testSimulatedCloseDuringScanningWaitsForCleanupAndCreatesNoProfile() {
        let app = launchSimulatedCaptureApp()
        openSimulatedCapture(in: app)

        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
        app.buttons["capture.start"].tap()
        XCTAssertTrue(app.buttons["capture.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.closeDiscard"].waitForExistence(timeout: 5))
        app.buttons["capture.closeDiscard"].tap()
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 5))
        app.buttons["home.existingRooms"].tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
    }

    func testSimulatedCloseDuringProcessingWaitsForCleanupAndCreatesNoProfile() {
        let app = launchSimulatedCaptureApp(extraArguments: ["--simulated-processing-suspend"])
        openSimulatedCapture(in: app)
        advanceSimulatedCaptureToProcessing(in: app)

        XCTAssertTrue(
            identifiedElement("capture.processing", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["capture.closeDiscard"].waitForExistence(timeout: 5))
        app.buttons["capture.closeDiscard"].tap()
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 5))
        app.buttons["home.existingRooms"].tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
    }

    func testSimulatedPhotoFailureShowsFeedbackAndReenablesStop() {
        let app = launchSimulatedCaptureApp(extraArguments: ["--simulated-photo-failure"])
        openSimulatedCapture(in: app)

        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
        app.buttons["capture.start"].tap()
        XCTAssertTrue(app.buttons["capture.referencePhoto"].waitForExistence(timeout: 5))
        app.buttons["capture.referencePhoto"].tap()
        XCTAssertTrue(
            identifiedElement("capture.photoError", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["capture.stop"].isEnabled)
    }

    func testSimulatedGPSDenialKeepsManualLocationSaveAvailable() {
        let app = launchSimulatedCaptureApp(extraArguments: ["--simulated-gps-denied"])
        openSimulatedCapture(in: app)

        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.requestGPS"].waitForExistence(timeout: 5))
        app.buttons["capture.requestGPS"].press(forDuration: 0.15)
        XCTAssertTrue(app.staticTexts["capture.gpsDenied"].waitForExistence(timeout: 5))
        app.buttons["capture.start"].tap()
        XCTAssertTrue(app.buttons["capture.stop"].waitForExistence(timeout: 5))
        app.buttons["capture.stop"].tap()
        XCTAssertTrue(app.textFields["capture.manualLocation"].waitForExistence(timeout: 5))
        app.textFields["capture.manualLocation"].tap()
        app.textFields["capture.manualLocation"].typeText(" Manual")
        XCTAssertTrue(app.buttons["capture.save"].waitForExistence(timeout: 5))
        app.buttons["capture.save"].tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5))
    }

    func testSimulatedSaveFailureRetainsReviewThenDiscardCreatesNoProfile() {
        let app = launchSimulatedCaptureApp(extraArguments: ["--simulated-save-failure"])
        openSimulatedCapture(in: app)
        advanceSimulatedCaptureToReview(in: app)

        app.buttons["capture.save"].tap()
        XCTAssertTrue(app.staticTexts["capture.saveError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.discard"].waitForExistence(timeout: 5))
        app.buttons["capture.discard"].tap()
        XCTAssertTrue(app.buttons["home.existingRooms"].waitForExistence(timeout: 5))
        app.buttons["home.existingRooms"].tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
    }

    func testSimulatedProcessingFailureCanRetryOnceOrDiscardPersistentlyFailingAttempt() {
        let retryApp = launchSimulatedCaptureApp(extraArguments: ["--simulated-processing-fail-once"])
        openSimulatedCapture(in: retryApp)
        advanceSimulatedCaptureToProcessing(in: retryApp)
        XCTAssertTrue(retryApp.buttons["capture.retry"].waitForExistence(timeout: 5))
        retryApp.buttons["capture.retry"].tap()
        XCTAssertTrue(retryApp.buttons["capture.save"].waitForExistence(timeout: 5))
        retryApp.buttons["capture.save"].tap()
        XCTAssertTrue(retryApp.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5))

        let discardApp = launchSimulatedCaptureApp(extraArguments: ["--simulated-processing-failure"])
        openSimulatedCapture(in: discardApp)
        advanceSimulatedCaptureToProcessing(in: discardApp)
        XCTAssertTrue(discardApp.buttons["capture.retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(discardApp.buttons["capture.closeDiscard"].waitForExistence(timeout: 5))
        discardApp.buttons["capture.closeDiscard"].tap()
        XCTAssertTrue(discardApp.buttons["home.existingRooms"].waitForExistence(timeout: 5))
        discardApp.buttons["home.existingRooms"].tap()
        XCTAssertTrue(discardApp.staticTexts["library.empty"].waitForExistence(timeout: 5))
    }

    func testCloudBackupIsDisabledAndUnconfiguredWithoutAutomaticLaunchOperation() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.buttons["home.cloudBackupSettings"].waitForExistence(timeout: 5))
        app.buttons["home.cloudBackupSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings & privacy"].waitForExistence(timeout: 5))
        let settingsScroll = app.scrollViews["cloudBackup.scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        let enable = app.switches["cloudBackup.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        scrollIntoView(enable, in: settingsScroll)
        XCTAssertTrue(enable.isHittable)
        enable.tap()
        XCTAssertFalse(app.staticTexts["cloudBackup.accountStatus"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cloudBackup.error"].exists)
        let check = app.buttons["cloudBackup.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        scrollIntoView(check, in: settingsScroll)
        XCTAssertTrue(check.isHittable)
        check.tap()
        let error = app.descendants(matching: .any)["cloudBackup.error"]
        XCTAssertTrue(waitForHittable(error, in: settingsScroll))
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        // No account/list/backup screen is auto-triggered merely by opening or
        // enabling the local setting; the error is the explicit Check action.
    }

    func testHomeSettingsDisclosesUnconfiguredPrivacyPolicyWithoutInventingALink() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.buttons["home.cloudBackupSettings"].waitForExistence(timeout: 5))
        app.buttons["home.cloudBackupSettings"].tap()

        XCTAssertTrue(app.navigationBars["Settings & privacy"].waitForExistence(timeout: 5))
        let settingsScroll = app.scrollViews["cloudBackup.scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        let notConfigured = app.descendants(matching: .any)["settings.privacyPolicyNotConfigured"]
        XCTAssertTrue(waitForHittable(notConfigured, in: settingsScroll))
        XCTAssertTrue(notConfigured.waitForExistence(timeout: 5))
        XCTAssertFalse(app.links["settings.privacyPolicyLink"].exists)
    }

    func testFakeCloudBackupRequiresExplicitListBackupAndRecoverCopyAction() {
        // The fake transport removes CloudKit latency, but this end-to-end
        // guard still builds and validates a real local project archive.
        executionTimeAllowance = 120
        let app = launchFakeCloudBackupApp()
        saveMockRoom(in: app)
        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.infoToggle"].waitForExistence(timeout: 5))
        app.buttons["detail.infoToggle"].tap()
        let detailBackup = app.buttons["detail.backup"]
        XCTAssertTrue(detailBackup.waitForExistence(timeout: 5))
        scrollIntoView(detailBackup, in: app.scrollViews["detail.infoPanel.scroll"])
        XCTAssertTrue(detailBackup.isHittable)
        detailBackup.tap()
        XCTAssertTrue(app.navigationBars["Settings & privacy"].waitForExistence(timeout: 5))
        let settingsScroll = app.scrollViews["cloudBackup.scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        let check = app.buttons["cloudBackup.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        scrollIntoView(check, in: settingsScroll)
        XCTAssertTrue(check.isHittable)
        XCTAssertFalse(app.staticTexts["cloudBackup.accountStatus"].exists)
        check.tap()
        let accountStatus = app.staticTexts["cloudBackup.accountStatus"]
        XCTAssertTrue(accountStatus.waitForExistence(timeout: 5))
        let list = app.buttons["cloudBackup.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        scrollIntoView(list, in: settingsScroll, direction: .forward)
        XCTAssertTrue(list.isHittable)
        list.tap()
        let listStatus = app.staticTexts["cloudBackup.listStatus"]
        XCTAssertTrue(listStatus.waitForExistence(timeout: 5))
        let backup = app.buttons["cloudBackup.backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        scrollIntoView(backup, in: settingsScroll)
        XCTAssertTrue(backup.isHittable)
        backup.tap()
        let prepare = app.buttons["cloudBackup.prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 15))
        scrollIntoView(prepare, in: settingsScroll)
        XCTAssertTrue(prepare.isHittable)
        prepare.tap()
        let recoverCopy = app.buttons["cloudBackup.recoverCopy"]
        XCTAssertTrue(recoverCopy.waitForExistence(timeout: 15))
        // Prepared recovery renders immediately above the record action that
        // was just tapped. Two bounded downward swipes reach it on each
        // supported form factor without a 30-second bidirectional scan.
        for _ in 0..<2 where !recoverCopy.isHittable {
            swipe(settingsScroll, direction: .backward)
        }
        XCTAssertTrue(recoverCopy.isHittable)
        recoverCopy.tap()
        let outcome = identifiedElement("cloudBackup.recoveryOutcome", in: app)
        XCTAssertTrue(outcome.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["cloudBackup.close"].waitForExistence(timeout: 5))
    }

    func testFakeCloudAccountUnavailableIsVisibleOnlyAfterExplicitCheck() {
        let app = launchFakeCloudBackupApp(extraArguments: ["--fake-cloud-account-unavailable"])
        XCTAssertTrue(app.buttons["home.cloudBackupSettings"].waitForExistence(timeout: 5))
        app.buttons["home.cloudBackupSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings & privacy"].waitForExistence(timeout: 5))
        let settingsScroll = app.scrollViews["cloudBackup.scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        let check = app.buttons["cloudBackup.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        scrollIntoView(check, in: settingsScroll)
        XCTAssertTrue(check.isHittable)
        XCTAssertFalse(app.staticTexts["cloudBackup.accountStatus"].exists)
        check.tap()
        let accountStatus = app.staticTexts["cloudBackup.accountStatus"]
        XCTAssertTrue(waitForHittable(accountStatus, in: settingsScroll))
        XCTAssertTrue(accountStatus.waitForExistence(timeout: 5))
    }

    func testSlice5MigrationPreviewMakesApprovalRetryAndLocalRetentionExplicit() {
        let app = launchSlice5ProfessionalFixture(
            extraArguments: ["--slice5-professional-ui-retry"]
        )
        let scroll = app.scrollViews["professional.sync.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Professional project sync"].waitForExistence(timeout: 5))

        let approve = app.buttons["professional.sync.approve"]
        let retry = app.buttons["professional.sync.retry"]
        scrollIntoView(approve, in: scroll)
        XCTAssertTrue(approve.isHittable)
        XCTAssertTrue(retry.exists)
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "never deletes")
        ).firstMatch.exists)
        attachSlice5Screenshot(named: "slice5-migration-preview-retry", app: app)
    }

    func testSlice5StaleHeadPreservesBothBranchesAndRequiresExplicitResolution() {
        let app = launchSlice5ProfessionalFixture(
            extraArguments: ["--slice5-professional-ui-conflict"]
        )
        let scroll = app.scrollViews["professional.sync.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let compare = app.buttons["professional.sync.conflict.compare"]
        let rebase = app.buttons["professional.sync.conflict.rebase"]
        let duplicate = app.buttons["professional.sync.conflict.duplicate"]
        scrollIntoView(compare, in: scroll)
        XCTAssertTrue(compare.isHittable)
        XCTAssertTrue(rebase.exists)
        XCTAssertTrue(duplicate.exists)
        compare.tap()
        XCTAssertTrue(
            identifiedElement("professional.sync.conflict.comparison", in: app)
                .waitForExistence(timeout: 5)
        )
        attachSlice5Screenshot(named: "slice5-stale-head-comparison", app: app)
    }

    func testSlice5RawArchiveIsSeparateReviewedOptIn() {
        let app = launchSlice5ProfessionalFixture(
            extraArguments: ["--slice5-professional-ui-raw"]
        )
        let scroll = app.scrollViews["professional.sync.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let rawApproval = app.buttons["professional.sync.rawApprove"]
        scrollIntoView(rawApproval, in: scroll)
        XCTAssertTrue(rawApproval.isHittable)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "never advances")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Size and privacy review")
        ).firstMatch.exists)
        attachSlice5Screenshot(named: "slice5-raw-archive-review", app: app)
    }

    func testSlice5DesktopWidthLandscapeScenarios() {
        let migration = launchSlice5ProfessionalFixture(
            extraArguments: ["--slice5-professional-ui-retry"],
            landscape: true
        )
        let migrationScroll = migration.scrollViews["professional.sync.scroll"]
        XCTAssertTrue(migrationScroll.waitForExistence(timeout: 5))
        let approve = migration.buttons["professional.sync.approve"]
        scrollIntoView(approve, in: migrationScroll)
        XCTAssertTrue(approve.isHittable)
        attachSlice5Screenshot(named: "slice5-migration-preview-retry", app: migration)
        migration.terminate()

        let raw = launchSlice5ProfessionalFixture(
            extraArguments: ["--slice5-professional-ui-raw"],
            landscape: true
        )
        let rawScroll = raw.scrollViews["professional.sync.scroll"]
        XCTAssertTrue(rawScroll.waitForExistence(timeout: 5))
        let rawApproval = raw.buttons["professional.sync.rawApprove"]
        scrollIntoView(rawApproval, in: rawScroll)
        XCTAssertTrue(rawApproval.isHittable)
        attachSlice5Screenshot(named: "slice5-raw-archive-review", app: raw)
        raw.terminate()

        let conflict = launchSlice5ProfessionalFixture(
            extraArguments: ["--slice5-professional-ui-conflict"],
            landscape: true
        )
        let conflictScroll = conflict.scrollViews["professional.sync.scroll"]
        XCTAssertTrue(conflictScroll.waitForExistence(timeout: 5))
        let compare = conflict.buttons["professional.sync.conflict.compare"]
        scrollIntoView(compare, in: conflictScroll)
        XCTAssertTrue(compare.isHittable)
        compare.tap()
        XCTAssertTrue(
            identifiedElement("professional.sync.conflict.comparison", in: conflict)
                .waitForExistence(timeout: 5)
        )
        attachSlice5Screenshot(named: "slice5-stale-head-comparison", app: conflict)
    }

    // MARK: - Slice 7 trash UI regression helpers

    func attachTrashScreenshot(_ app: XCUIApplication, _ valID: String, _ slug: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(valID)-\(slug)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func trashTestPaperBrightness(in app: XCUIApplication) throws -> Double {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        // Sample the outer paper margin, away from cards, text and chrome.
        let sample = try XCTUnwrap(image.cropping(to: CGRect(
            x: 8, y: image.height / 2, width: 1, height: 1
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }

    func attachTrashText(_ valID: String, _ slug: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(valID)-\(slug)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func saveTrashTestRooms(_ count: Int, in app: XCUIApplication) {
        for number in 1...count {
            if number > 1 {
                XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(app.buttons["home.newRoomScan"].waitForExistence(timeout: 10))
            }
            saveMockRoom(in: app)
            let id = String(format: "ui-project-%03d", number)
            XCTAssertTrue(app.buttons["library.project.\(id)"].waitForExistence(timeout: 10))
        }
    }

    func selectTrashTestFilter(_ filter: String, in app: XCUIApplication) {
        let button = app.buttons["library.show\(filter)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        scrollIntoView(button, in: app, direction: .backward)
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func assertTrashTestMembership(
        in app: XCUIApplication,
        present: [String],
        absent: [String] = []
    ) {
        for id in present {
            let row = app.buttons["library.project.\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Expected \(id) in the selected filter.")
        }
        for id in absent {
            XCTAssertTrue(app.buttons["library.project.\(id)"].waitForNonExistence(timeout: 10),
                          "\(id) must not appear in the selected filter.")
        }
    }

    func assertTrashTestEmpty(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.project.")).count, 0)
    }

    private func assertTrashTestOrder(_ ids: [String], in app: XCUIApplication) {
        assertTrashTestMembership(in: app, present: ids)
        let rows = ids.map { app.buttons["library.project.\($0)"] }
        scrollIntoView(rows[0], in: app, direction: .backward)
        let exposedIDs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.project."))
            .allElementsBoundByAccessibilityElement.map(\.identifier)
        XCTAssertEqual(exposedIDs, ids.map { "library.project.\($0)" })
        // Frames are a second oracle independent of query enumeration order.
        for (upper, lower) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(upper.frame.minY, lower.frame.minY)
        }
        attachTrashText("VAL-TRASH-017", "row-order-\(ids.joined(separator: "-"))",
                        rows.map { "\($0.identifier): \($0.frame)" }.joined(separator: "\n"))
    }

    func assertTrashRelaunchMembership(in app: XCUIApplication, present: [String], absent: [String] = []) {
        assertTrashTestMembership(in: app, present: present, absent: absent)
    }

    private func assertTrashTestTarget(_ element: XCUIElement) {
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isEnabled)
        XCTAssertTrue(element.isHittable)
        // CGFloat subtraction can report 43.99999999999997 for a 44-pt
        // frame. Allow floating-point noise, not a sub-point target.
        XCTAssertGreaterThanOrEqual(element.frame.width + 0.000001, 44, element.identifier)
        XCTAssertGreaterThanOrEqual(element.frame.height + 0.000001, 44, element.identifier)
    }

    private func assertTrashTestFullyVisible(_ element: XCUIElement, in scrollView: XCUIElement) {
        // Hittable includes partially visible targets. Scroll until the whole
        // element fits, then assert its frame instead of accepting that proxy.
        let app = XCUIApplication()
        let window = app.windows.firstMatch.frame
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        let viewport = scrollView.frame.intersection(window)
        let visible = CGRect(x: viewport.minX, y: max(viewport.minY, navigationBottom),
                             width: viewport.width,
                             height: viewport.maxY - max(viewport.minY, navigationBottom))
        for _ in 0..<6 where !visible.insetBy(dx: -1, dy: -1).contains(element.frame) {
            swipe(scrollView, direction: element.frame.maxY > visible.maxY ? .forward : .backward)
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThan(element.frame.height, 0)
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(element.frame),
                      "\(element.identifier) must fit without clipping: element=\(element.frame), viewport=\(visible)")
    }

    private func assertTrashTestFilterTargets(in app: XCUIApplication, valID: String = "VAL-TRASH-019") {
        var frames: [String] = []
        for filter in ["Active", "Archived", "Trash"] {
            selectTrashTestFilter(filter, in: app)
            let button = app.buttons["library.show\(filter)"]
            assertTrashTestTarget(button)
            assertTrashTestFullyVisible(button, in: app.scrollViews.firstMatch)
            frames.append("\(button.identifier): \(button.frame)")
            attachTrashScreenshot(app, valID, "filter-\(filter.lowercased())-44-point-target")
        }
        attachTrashText(valID, "filter-target-frames", frames.joined(separator: "\n"))
        selectTrashTestFilter("Active", in: app)
    }

    func openTrashTestProject(_ id: String, in app: XCUIApplication) {
        let row = app.buttons["library.project.\(id)"]
        scrollIntoView(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["detail.scroll"].waitForExistence(timeout: 10))
    }

    func backToTrashTestLibrary(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(app.buttons["library.showActive"].waitForExistence(timeout: 10))
    }

    private func openTrashTestInfo(in app: XCUIApplication) {
        let toggle = app.buttons["detail.infoToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        XCTAssertTrue(app.buttons["detail.infoPanel.close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["detail.infoPanel.scroll"].waitForExistence(timeout: 10))
    }

    private func closeTrashTestInfo(in app: XCUIApplication) {
        let close = app.buttons["detail.infoPanel.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
    }

    private func trashTestHead(in app: XCUIApplication) -> String {
        let head = app.staticTexts["detail.headRevision"]
        let openedInfo = !head.exists
        if openedInfo { openTrashTestInfo(in: app) }
        XCTAssertTrue(head.waitForExistence(timeout: 10))
        let value = head.label
        XCTAssertFalse(value.isEmpty)
        if openedInfo { closeTrashTestInfo(in: app) }
        return value
    }

    private func tapTrashTestDetailAction(_ identifier: String, in app: XCUIApplication) {
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        let scroll = app.scrollViews["detail.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scrollIntoView(action, in: scroll)
        if identifier == "detail.trash" || identifier == "detail.delete" {
            scroll.swipeUp() // Expose the whole bottom action, not just its top edge.
        }
        XCTAssertTrue(action.isHittable)
        action.tap()
    }

    private func trashTestConfirmation(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: identifier)
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10))
        let hittable = buttons.allElementsBoundByAccessibilityElement.filter(\.isHittable)
        // iOS 26 can expose the same SwiftUI confirmation as a button inside
        // a button. Collapse only exact label/frame aliases, not real choices.
        let targets = Set(hittable.map { "\($0.identifier)|\($0.label)|\($0.frame)" })
        XCTAssertEqual(targets.count, 1, "Expected one confirmation target, not distinct destructive choices.")
        return hittable.first ?? buttons.firstMatch
    }

    func moveTrashTestProjectToTrash(in app: XCUIApplication, valID: String, slug: String) {
        XCTAssertFalse(app.buttons["detail.delete"].exists)
        tapTrashTestDetailAction("detail.trash", in: app)
        let confirm = trashTestConfirmation("trash.confirm", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "30 days")).firstMatch.exists)
        attachTrashScreenshot(app, valID, "\(slug)-confirmation")
        confirm.tap()
        XCTAssertTrue(app.buttons["library.showActive"].waitForExistence(timeout: 10),
                      "Trash must dismiss detail and refresh the selected library filter.")
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForNonExistence(timeout: 10))
        attachTrashScreenshot(app, valID, "\(slug)-dismissed-library")
    }

    private func setTrashTestArchived(_ archived: Bool, in app: XCUIApplication) {
        openTrashTestInfo(in: app)
        let action = app.buttons[archived ? "detail.archive" : "detail.unarchive"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        scrollIntoView(action, in: app.scrollViews["detail.infoPanel.scroll"])
        XCTAssertTrue(action.isHittable)
        action.tap()
        XCTAssertTrue(app.buttons["detail.infoPanel.close"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 10))
    }

    func trashTestPurgeLabel(_ projectID: String, in app: XCUIApplication) -> String {
        let purge = app.staticTexts["library.project.\(projectID).purgeDate"]
        XCTAssertTrue(purge.waitForExistence(timeout: 10))
        scrollIntoView(purge, in: app)
        XCTAssertTrue(purge.label.hasPrefix("Deletes permanently on "))
        XCTAssertFalse(purge.label.contains("…"))
        return purge.label
    }

    private func assertTrashTestBadge(_ label: String, projectID: String, in app: XCUIApplication) {
        let row = app.buttons["library.project.\(projectID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // SwiftUI may combine a NavigationLink's label into its button rather
        // than expose child Text elements; both forms must carry the badge.
        XCTAssertTrue(row.staticTexts[label].exists || row.label.contains(label))
    }

    private func assertTrashTestNoBadge(_ label: String, projectID: String, in app: XCUIApplication) {
        let row = app.buttons["library.project.\(projectID)"]
        XCTAssertFalse(row.staticTexts[label].exists)
        XCTAssertFalse(row.label.contains(label))
    }

    private var trashTestForbiddenIdentifiers: [String] {
        [
            "detail.trash", "detail.editRoom", "detail.rescan", "detail.duplicate",
            "detail.editMetadata", "detail.reviewOrientation", "detail.aiRedesign",
            "detail.publicationReview", "detail.export", "detail.exportBundle", "detail.backup",
            "detail.archive", "detail.unarchive", "ai.prepare", "ai.workspace", "ai.share",
        ]
    }

    private func assertTrashTestNoMutations(in app: XCUIApplication, slug: String) {
        for identifier in trashTestForbiddenIdentifiers {
            for element in app.descendants(matching: .any).matching(identifier: identifier)
                .allElementsBoundByAccessibilityElement {
                XCTAssertFalse(element.isEnabled, "\(identifier) must be absent or disabled while trashed (\(slug)).")
            }
        }
        attachTrashText("VAL-TRASH-022", "\(slug)-mutation-and-outbound-inventory",
                        "Checked absent-or-disabled: \(trashTestForbiddenIdentifiers.joined(separator: ", "))\n"
                        + trashTestElementInventory(in: app))
    }

    private func trashTestElementInventory(in app: XCUIApplication) -> String {
        app.descendants(matching: .any).allElementsBoundByAccessibilityElement
            .filter { $0.identifier.hasPrefix("detail.") || $0.identifier.hasPrefix("ai.") }
            .map { "\($0.identifier): type=\($0.elementType.rawValue), enabled=\($0.isEnabled), frame=\($0.frame)" }
            .joined(separator: "\n")
    }

    private func assertTrashTestReadOnlyDetail(in app: XCUIApplication, purgeLabel: String) {
        let banner = identifiedElement("detail.trashBanner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.contains("In Trash"))
        let date = String(purgeLabel.dropFirst("Deletes permanently on ".count))
        XCTAssertTrue(banner.label.localizedCaseInsensitiveContains("deletes permanently on \(date)"))
        scrollIntoView(banner, in: app.scrollViews["detail.scroll"], direction: .backward)
        attachTrashScreenshot(app, "VAL-TRASH-022", "read-only-trash-banner")
        for id in ["detail.restore", "detail.delete"] {
            let action = app.buttons[id]
            XCTAssertTrue(action.waitForExistence(timeout: 10))
            scrollIntoView(action, in: app.scrollViews["detail.scroll"])
            assertTrashTestTarget(action)
        }
        XCTAssertTrue(app.buttons["detail.delete"].label.contains("Delete now"))
        XCTAssertTrue(app.staticTexts["detail.roomName"].exists)
        assertTrashTestNoMutations(in: app, slug: "base-detail")
        attachTrashScreenshot(app, "VAL-TRASH-022", "restore-and-delete-now-actions")
        if app.buttons["detail.infoToggle"].exists {
            openTrashTestInfo(in: app)
            XCTAssertTrue(app.staticTexts["detail.headRevision"].waitForExistence(timeout: 10))
            assertTrashTestNoMutations(in: app, slug: "info-panel")
            attachTrashScreenshot(app, "VAL-TRASH-022", "read-only-info-panel")
            closeTrashTestInfo(in: app)
        } else {
            XCTAssertTrue(app.staticTexts["detail.headRevision"].waitForExistence(timeout: 10))
        }
        let viewer = app.buttons["detail.view"]
        if viewer.exists && viewer.isEnabled {
            tapTrashTestDetailAction("detail.view", in: app)
            XCTAssertTrue(app.buttons["viewer.close"].waitForExistence(timeout: 10))
            assertTrashTestNoMutations(in: app, slug: "read-only-viewer")
            let outbound = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier CONTAINS[c] 'export' OR identifier CONTAINS[c] 'publication' OR identifier CONTAINS[c] 'backup' OR identifier == 'ai.share'"
            )).allElementsBoundByAccessibilityElement
            for element in outbound { XCTAssertFalse(element.isEnabled, element.identifier) }
            attachTrashScreenshot(app, "VAL-TRASH-022", "viewer-has-no-outbound-controls")
            app.buttons["viewer.close"].tap()
            XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 10))
        }
    }

    private func confirmTrashTestDeleteWithBackupDisabled(in app: XCUIApplication, slug: String) {
        tapTrashTestDetailAction("detail.delete", in: app)
        let confirm = trashTestConfirmation("delete.confirm", in: app)
        XCTAssertEqual(confirm.label, "Delete now")
        XCTAssertFalse(app.buttons["delete.confirmWithBackup"].exists)
        // A single-choice dialog may expose a duplicate presentation wrapper;
        // count actionable choices, as in trashTestConfirmation above.
        let destructiveChoices = app.buttons.allElementsBoundByAccessibilityElement.filter {
            $0.isHittable && ($0.label.hasPrefix("Delete now") || $0.identifier.hasPrefix("delete.confirm"))
        }
        XCTAssertEqual(Set(destructiveChoices.map { "\($0.label)|\($0.frame)" }).count, 1)
        let copy = app.staticTexts.allElementsBoundByAccessibilityElement.map(\.label).joined(separator: " ").lowercased()
        for forbidden in ["erased", "wiped", "instantly", "immediately", "all devices"] {
            XCTAssertFalse(copy.contains(forbidden), "Delete copy must not promise physical erasure.")
        }
        attachTrashScreenshot(app, "VAL-TRASH-025", "\(slug)-single-choice-delete-confirmation")
        confirm.tap()
        XCTAssertTrue(app.buttons["library.showTrash"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Settings & privacy"].exists,
                       "Finishing a local purge must not require a Cloud Backup sheet.")
    }

    func seedTrashTestRedesignThroughUI(in app: XCUIApplication) {
        tapTrashTestDetailAction("detail.reviewOrientation", in: app)
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        let request = app.descendants(matching: .any)["orientation.request"]
        // Form cells are virtualized, unlike the detail ScrollView.
        scrollIntoView(request, in: form)
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.tap()
        request.typeText("Synthetic trash regression: preserve captured shell.")
        let save = app.buttons["orientation.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 10))
    }

    struct TrashTestRoots {
        let temporary: URL
        let token: String

        func root(_ kind: String) -> URL {
            temporary.appendingPathComponent("RoomScanStudio-UI-Testing-\(kind)-\(token)", isDirectory: true)
        }
    }

    private enum TrashTestFileError: Error {
        case unsafePath(String)
        case missingRoot
        case invalidSourceBinding
    }

    func trashTestRoots(token: String) throws -> TrashTestRoots? {
        #if targetEnvironment(simulator)
        // Discover the app's sibling data container from the runner's own
        // Simulator container. No host path or simulator/device ID is baked in.
        let applicationContainers = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .deletingLastPathComponent()
        guard applicationContainers.lastPathComponent == "Application" else {
            throw TrashTestFileError.unsafePath("Unexpected Simulator runner container layout.")
        }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: applicationContainers, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        var roots: [TrashTestRoots] = []
        for candidate in candidates {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let temporary = candidate.appendingPathComponent("tmp", isDirectory: true)
            let owned = TrashTestRoots(temporary: temporary, token: token)
            let project = owned.root("Projects").appendingPathComponent("ui-project-001", isDirectory: true)
            guard FileManager.default.fileExists(atPath: project.appendingPathComponent("metadata.json").path) else { continue }
            try requireTrashTestSafePath(project, under: temporary)
            roots.append(owned)
        }
        guard roots.count == 1, let root = roots.first else { throw TrashTestFileError.missingRoot }
        return root
        #else
        // iOS sandboxes prohibit sibling-container inspection. The device run
        // retains UI evidence only; file deletion proof is Simulator-tier.
        attachTrashText("VAL-TRASH-025", "device-file-oracle-unavailable",
                        "Physical-device sandbox: no companion seeding/inspection outside the runner. "
                        + "VAL-TRASH-025 filesystem proof requires the Simulator run.")
        return nil
        #endif
    }

    func requireTrashTestSafePath(_ url: URL, under temporary: URL) throws {
        let base = temporary.standardizedFileURL
        let path = url.standardizedFileURL
        guard path.path.hasPrefix(base.path + "/") else {
            throw TrashTestFileError.unsafePath("Path is not inside the test app's temporary directory.")
        }
        var current = path
        while current.path != base.path {
            do {
                // lstat-style attributes catch dangling links too; fileExists
                // would follow them and incorrectly report "not present".
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw TrashTestFileError.unsafePath("Refusing any symlink in the owned fixture tree.")
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                // A new fixture may have not-yet-created path components.
            }
            current.deleteLastPathComponent()
        }
        let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TrashTestFileError.unsafePath("The app temporary directory must be a real directory.")
        }
    }

    func seedTrashTestOwnedConcept(in roots: TrashTestRoots, projectID: String, token: String) throws {
        let redesignRoot = roots.root("RedesignState").appendingPathComponent(projectID, isDirectory: true)
        try requireTrashTestSafePath(redesignRoot, under: roots.temporary)
        let states = try FileManager.default.contentsOfDirectory(at: redesignRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
        guard states.count == 1, let state = states.first else { throw TrashTestFileError.invalidSourceBinding }
        try requireTrashTestSafePath(state, under: roots.temporary)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any]
        guard let source = document?["sourceRevision"] as? [String: Any],
              source["projectID"] as? String == projectID,
              let revisionID = source["revisionID"] as? String,
              revisionID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let digest = source["revisionManifestSHA256"] as? String,
              digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        else { throw TrashTestFileError.invalidSourceBinding }
        let directory = roots.root("ConceptSets").appendingPathComponent(projectID)
            .appendingPathComponent(revisionID).appendingPathComponent(digest)
            .appendingPathComponent("ui-trash-owned-concept", isDirectory: true)
        try requireTrashTestSafePath(directory, under: roots.temporary)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw TrashTestFileError.unsafePath("Never overwrite an existing Concept Set fixture.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ownership: [String: Any] = [
            "formatVersion": "roomscan-concept-store-ownership-v1",
            "sourceRevision": source,
            "conceptSetID": "ui-trash-owned-concept",
            "transactionID": UUID().uuidString.lowercased(),
        ]
        let marker = try JSONSerialization.data(withJSONObject: ownership, options: [.sortedKeys, .withoutEscapingSlashes])
        try marker.write(to: directory.appendingPathComponent(".roomscan-concept-ownership.json"), options: .withoutOverwriting)
        // This is a real marker-owned cleanup fixture, not a screen fixture or
        // a claim that a full semantic Concept Set was imported through UI.
        let fixtureOwner = try JSONSerialization.data(
            withJSONObject: ["token": token, "projectID": projectID, "purpose": "synthetic-trash-ui-cleanup"],
            options: [.sortedKeys]
        )
        try fixtureOwner.write(to: directory.appendingPathComponent(".roomscan-ui-trash-test-ownership.json"),
                               options: .withoutOverwriting)
        try Data("Synthetic Concept Set companion bytes for \(projectID)".utf8)
            .write(to: directory.appendingPathComponent("retained-companion.txt"), options: .withoutOverwriting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".roomscan-concept-ownership.json").path))
        XCTAssertFalse(try trashTestBytes(directory, under: roots.temporary).isEmpty)
    }

    func trashTestBytes(_ directory: URL, under temporary: URL) throws -> [String: Data] {
        try requireTrashTestSafePath(directory, under: temporary)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        var bytes: [String: Data] = [:]
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try requireTrashTestSafePath(entry, under: temporary)
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw TrashTestFileError.unsafePath("Fixture symlink.") }
            if values.isDirectory == true {
                for (name, data) in try trashTestBytes(entry, under: temporary) {
                    bytes["\(entry.lastPathComponent)/\(name)"] = data
                }
            } else {
                guard values.isRegularFile == true else { throw TrashTestFileError.unsafePath("Non-regular fixture file.") }
                bytes[entry.lastPathComponent] = try Data(contentsOf: entry)
            }
        }
        return bytes
    }

    private func trashTestCompanionBytes(_ roots: TrashTestRoots, projectID: String) throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for kind in ["RedesignState", "ConceptSets"] {
            let files = try trashTestBytes(roots.root(kind).appendingPathComponent(projectID), under: roots.temporary)
            XCTAssertFalse(files.isEmpty, "Positive control: \(kind)/\(projectID) must really be seeded.")
            for (name, data) in files { bytes["\(kind)/\(name)"] = data }
        }
        return bytes
    }

    func trashTestProjectAndCompanionBytes(_ roots: TrashTestRoots, projectID: String) throws -> [String: Data] {
        var bytes = try trashTestCompanionBytes(roots, projectID: projectID)
        let package = try trashTestBytes(roots.root("Projects").appendingPathComponent(projectID), under: roots.temporary)
        XCTAssertFalse(package.isEmpty)
        for (name, data) in package { bytes["Projects/\(name)"] = data }
        return bytes
    }

    func assertTrashTestPurgeOnDisk(_ roots: TrashTestRoots, projectID: String) throws {
        for kind in ["Projects", "RedesignState", "ConceptSets"] {
            let directory = roots.root(kind).appendingPathComponent(projectID)
            try requireTrashTestSafePath(directory, under: roots.temporary)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "\(kind)/\(projectID) must be removed.")
        }
        let journal = roots.root("CloudBackupDeletionJournal").appendingPathComponent("records/\(projectID).json")
        try requireTrashTestSafePath(journal, under: roots.temporary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path),
                       "Disabled Cloud Backup must not create a deletion request.")
    }

    func attachTrashTestListing(_ roots: TrashTestRoots, _ valID: String, _ slug: String) throws {
        var lines = ["Synthetic Simulator token=\(roots.token); relative paths, byte counts and SHA-256 only (no file bodies)."]
        for kind in ["Projects", "RedesignState", "ConceptSets", "CloudBackupDeletionJournal"] {
            let root = roots.root(kind)
            try requireTrashTestSafePath(root, under: roots.temporary)
            lines.append("\(root.lastPathComponent)/: \(FileManager.default.fileExists(atPath: root.path) ? "present" : "absent")")
            for (name, data) in try trashTestBytes(root, under: roots.temporary).sorted(by: { $0.key < $1.key }) {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                lines.append("  \(name) bytes=\(data.count) sha256=\(digest)")
            }
        }
        attachTrashText(valID, slug, lines.joined(separator: "\n"))
    }

    func launchIsolatedApp(
        rootToken: String? = nil,
        keepRoot: Bool = false,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-mock-fixture",
        ]
        if let rootToken {
            app.launchArguments.append("--isolated-root-token=\(rootToken)")
        }
        if keepRoot {
            app.launchArguments.append("--keep-isolated-root")
        }
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    private func launchAccessibilityIsolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-mock-fixture",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        return app
    }

    private func launchSimulatedCaptureApp(
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-mock-fixture",
            "--use-simulated-capture",
        ] + extraArguments
        app.launch()
        return app
    }

    private func launchRescanFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-mock-fixture",
            "--use-deterministic-rescan-fixture",
        ]
        app.launch()
        return app
    }

    private func launchFakeCloudBackupApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-mock-fixture",
            "--use-fake-cloud-backup",
        ] + extraArguments
        app.launch()
        return app
    }

    private func launchSlice5ProfessionalFixture(
        extraArguments: [String] = [],
        landscape: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--slice5-professional-ui-fixture",
        ] + extraArguments
        app.launch()
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            let becameLandscape = XCTNSPredicateExpectation(
                predicate: NSPredicate { value, _ in
                    guard let element = value as? XCUIElement else { return false }
                    return element.frame.width > element.frame.height
                },
                object: window
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [becameLandscape], timeout: 5),
                .completed,
                "The desktop-width evidence fixture must actually render in landscape."
            )
            addTeardownBlock {
                XCUIDevice.shared.orientation = .portrait
            }
        }
        return app
    }

    private func attachSlice5Screenshot(
        named name: String,
        app: XCUIApplication
    ) {
        // XCUIApplication.screenshot() embeds a rotated portrait surface in a
        // landscape canvas on the Xcode 26 iPad runtime, while XCUIScreen keeps
        // the physical portrait pixel order. Normalize that runtime quirk only
        // after the independent window-frame oracle proves a landscape layout.
        let screenshot = XCUIScreen.main.screenshot()
        let window = app.windows.firstMatch
        let attachment: XCTAttachment
        if window.frame.width > window.frame.height,
           let source = UIImage(data: screenshot.pngRepresentation) {
            let size = CGSize(
                width: max(source.size.width, source.size.height),
                height: min(source.size.width, source.size.height)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = source.scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let normalized = renderer.image { context in
                if source.size.width > source.size.height {
                    // UIKit honors the screenshot's encoded image orientation
                    // while drawing and writes ordinary landscape pixel order.
                    source.draw(in: CGRect(origin: .zero, size: size))
                } else {
                    context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
                    context.cgContext.rotate(by: -.pi / 2)
                    source.draw(
                        in: CGRect(
                            x: -source.size.width / 2,
                            y: -source.size.height / 2,
                            width: source.size.width,
                            height: source.size.height
                        )
                    )
                }
            }
            guard let data = normalized.pngData() else {
                XCTFail("The landscape evidence screenshot must encode as PNG.")
                return
            }
            attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        } else {
            attachment = XCTAttachment(screenshot: screenshot)
        }
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSimulatedCapture(in app: XCUIApplication) {
        // Recorded 50-ms simulator taps sometimes left these targets unchanged.
        // Keep touch duration explicit, without retries or weaker assertions.
        app.buttons["home.newRoomScan"].press(forDuration: 0.15)
        XCTAssertTrue(app.buttons["newScan.openCapture"].waitForExistence(timeout: 5))
        app.buttons["newScan.openCapture"].press(forDuration: 0.15)
        XCTAssertTrue(app.staticTexts["capture.title"].waitForExistence(timeout: 5))
    }

    private func identifiedElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private enum ScrollDirection {
        case forward
        case backward
    }

    private func scrollIntoView(
        _ element: XCUIElement,
        in app: XCUIApplication,
        direction: ScrollDirection = .forward
    ) {
        scrollIntoView(element, in: app.scrollViews.firstMatch, direction: direction)
    }

    private func scrollIntoView(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        direction: ScrollDirection = .forward
    ) {
        for _ in 0..<12 where !element.isHittable {
            swipe(scrollView, direction: direction)
        }
        let fallbackDirection = opposite(direction)
        for _ in 0..<12 where !element.isHittable {
            swipe(scrollView, direction: fallbackDirection)
        }
    }

    private func waitForHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        direction: ScrollDirection = .forward,
        searchBothDirections: Bool = false,
        timeout: TimeInterval = 30
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var scanDirection = direction
        var swipesBeforeTurn = 2
        while Date() < deadline {
            for _ in 0..<swipesBeforeTurn {
                if element.isHittable {
                    return true
                }
                guard scrollView.exists else { return false }
                swipe(scrollView, direction: scanDirection)
                if Date() >= deadline {
                    break
                }
            }
            if searchBothDirections {
                // Recovery preparation blocks interactive dismissal while its
                // asynchronously inserted controls can shift either way.
                scanDirection = opposite(scanDirection)
                swipesBeforeTurn = min(swipesBeforeTurn + 2, 8)
            }
        }
        return element.isHittable
    }

    private func opposite(_ direction: ScrollDirection) -> ScrollDirection {
        switch direction {
        case .forward:
            return .backward
        case .backward:
            return .forward
        }
    }

    private func swipe(_ scrollView: XCUIElement, direction: ScrollDirection) {
        switch direction {
        case .forward:
            scrollView.swipeUp()
        case .backward:
            scrollView.swipeDown()
        }
    }

    private func waitForLabel(
        _ element: XCUIElement,
        equals expectedLabel: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expectedLabel)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func advanceSimulatedCaptureToProcessing(in app: XCUIApplication) {
        app.buttons["capture.prepare"].tap()
        XCTAssertTrue(app.buttons["capture.start"].waitForExistence(timeout: 5))
        app.buttons["capture.start"].tap()
        XCTAssertTrue(app.buttons["capture.stop"].waitForExistence(timeout: 5))
        app.buttons["capture.stop"].tap()
    }

    private func advanceSimulatedCaptureToReview(in app: XCUIApplication) {
        advanceSimulatedCaptureToProcessing(in: app)
        XCTAssertTrue(app.buttons["capture.save"].waitForExistence(timeout: 5))
    }

    private func openMockReview(in app: XCUIApplication) {
        let newRoomScan = app.buttons["home.newRoomScan"]
        XCTAssertTrue(newRoomScan.waitForExistence(timeout: 10))
        scrollIntoView(newRoomScan, in: app)
        XCTAssertTrue(newRoomScan.isHittable)
        newRoomScan.press(forDuration: 0.15)

        let mockReview = app.buttons["newScan.openMockReview"]
        XCTAssertTrue(mockReview.waitForExistence(timeout: 10))
        scrollIntoView(mockReview, in: app)
        XCTAssertTrue(mockReview.isHittable)
        mockReview.tap()
        XCTAssertTrue(app.staticTexts["mockReview.title"].waitForExistence(timeout: 10))
    }

    private func saveMockRoom(in app: XCUIApplication) {
        openMockReview(in: app)
        let save = app.buttons["mockReview.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        scrollIntoView(save, in: app)
        XCTAssertTrue(save.isHittable)
        save.tap()

        let openLibrary = app.buttons["mockReview.openLibrary"]
        XCTAssertTrue(openLibrary.waitForExistence(timeout: 10))
        scrollIntoView(openLibrary, in: app, direction: .backward)
        XCTAssertTrue(openLibrary.isHittable)
        openLibrary.tap()
        scrollIntoView(app.buttons["library.project.ui-project-001"], in: app)
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 10))
    }
}
