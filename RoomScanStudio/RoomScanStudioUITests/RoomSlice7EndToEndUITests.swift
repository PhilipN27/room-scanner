import XCTest

/// One composed personal-release journey across four launches that share a
/// single isolated root token. Every launch carries the isolated and fake
/// backup flags; launches after the first keep the root, and only the final
/// launch forces the Trash clock.
final class RoomSlice7EndToEndUITests: XCTestCase {
    private let wait: TimeInterval = 20
    private let shortWait: TimeInterval = 10
    private var nextStep = 1

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSlice7PersonalReleaseEndToEnd() throws {
        executionTimeAllowance = 1_200
        let token = String(UUID().uuidString.prefix(12))

        // Launch 1: scan -> review -> save -> AI package workspace.
        let first = launch(token: token, keepRoot: false)
        XCTAssertTrue(first.buttons["home.newRoomScan"].waitForExistence(timeout: wait))
        capture(first, "slice7-e2e-01-home")
        openMockReview(in: first)
        capture(first, "slice7-e2e-02-mock-review")
        let save = first.buttons["mockReview.save"]
        XCTAssertTrue(save.waitForExistence(timeout: shortWait))
        scrollIntoView(save, in: first.scrollViews.firstMatch)
        save.tap()
        let openLibrary = first.buttons["mockReview.openLibrary"]
        XCTAssertTrue(openLibrary.waitForExistence(timeout: wait))
        scrollIntoView(openLibrary, in: first.scrollViews.firstMatch, direction: .backward)
        openLibrary.tap()
        XCTAssertTrue(first.buttons["library.showActive"].waitForExistence(timeout: wait))
        XCTAssertTrue(first.buttons["library.project.ui-project-001"].waitForExistence(timeout: wait))
        capture(first, "slice7-e2e-03-saved-library")

        openProject("ui-project-001", in: first)
        saveOrientation(in: first)
        tapDetailAction("detail.aiRedesign", in: first)
        XCTAssertTrue(first.segmentedControls["ai.workspace"].waitForExistence(timeout: wait))
        let aiScroll = first.scrollViews["ai.scroll"]
        XCTAssertTrue(aiScroll.waitForExistence(timeout: shortWait))
        let brief = element("ai.brief", in: first)
        XCTAssertTrue(brief.waitForExistence(timeout: shortWait))
        if !((brief.value as? String) ?? "").contains("Synthetic") {
            scrollIntoView(brief, in: aiScroll)
            brief.tap()
            brief.typeText("Synthetic end-to-end brief: keep the captured shell.")
        }
        let prepare = first.buttons["ai.prepare"]
        scrollIntoView(prepare, in: aiScroll)
        XCTAssertTrue(prepare.isEnabled, "The saved orientation and brief must make the package ready.")
        prepare.tap()
        let acknowledge = first.switches["ai.provider.acknowledge"]
        XCTAssertTrue(acknowledge.waitForExistence(timeout: wait))
        XCTAssertTrue(waitFor(acknowledge, "isEnabled == true", timeout: 30), "Review never became ready.")
        scrollIntoView(acknowledge, in: aiScroll)
        capture(first, "slice7-e2e-04-ai-package-review-prepared")
        let closeAI = first.buttons["ai.close"]
        XCTAssertTrue(closeAI.waitForExistence(timeout: shortWait))
        closeAI.tap()
        XCTAssertTrue(first.segmentedControls["ai.workspace"].waitForNonExistence(timeout: shortWait))
        first.terminate()

        // Launch 2: concept import. Production import opens the system file
        // picker, which XCUITest cannot drive, so this one step uses the
        // pickerless --slice3-ui-fixture screen on the same kept root.
        let fixture = launch(token: token, keepRoot: true, extra: ["--slice3-ui-fixture"])
        let fixtureScroll = fixture.scrollViews["ai.scroll"]
        XCTAssertTrue(fixtureScroll.waitForExistence(timeout: wait))
        let complete = fixture.buttons["ai.profile.complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: shortWait))
        complete.tap()
        let fixturePrepare = fixture.buttons["ai.prepare"]
        scrollIntoView(fixturePrepare, in: fixtureScroll)
        fixturePrepare.tap()
        let fixtureAcknowledge = fixture.switches["ai.provider.acknowledge"]
        scrollFullyIntoView(fixtureAcknowledge, in: fixtureScroll)
        toggle(fixtureAcknowledge)
        XCTAssertEqual(fixtureAcknowledge.value as? String, "1")
        let rawConsent = fixture.switches["ai.complete.rawConsent"]
        scrollFullyIntoView(rawConsent, in: fixtureScroll)
        toggle(rawConsent)
        XCTAssertEqual(rawConsent.value as? String, "1")
        let approve = fixture.buttons["ai.disclosure.approve"]
        scrollIntoView(approve, in: fixtureScroll)
        approve.tap()
        let share = fixture.buttons["ai.share"]
        XCTAssertTrue(share.waitForExistence(timeout: wait))
        scrollIntoView(share, in: fixtureScroll)
        capture(fixture, "slice7-e2e-05-ai-package-approved")
        let conceptTab = fixture.segmentedControls["ai.workspace"].buttons["Concept Sets"]
        conceptTab.tap()
        let importLoose = fixture.buttons["concept.import.loose"]
        if !importLoose.waitForExistence(timeout: shortWait) {
            conceptTab.tap()
        }
        XCTAssertTrue(importLoose.waitForExistence(timeout: shortWait))
        importLoose.tap()
        let conceptScroll = fixture.scrollViews["concept.scroll"]
        XCTAssertTrue(conceptScroll.waitForExistence(timeout: shortWait))
        let mapping = fixture.staticTexts["concept.gallery-reference.mapping"]
        scrollIntoView(mapping, in: conceptScroll)
        XCTAssertTrue(mapping.exists)
        XCTAssertTrue(fixture.buttons["concept.imported-3.compare"].waitForExistence(timeout: shortWait))
        capture(fixture, "slice7-e2e-06-concept-set-imported")
        fixture.terminate()

        // Launch 3: export, backup, recovery, Trash lifecycle and deletion.
        let app = launch(token: token, keepRoot: true)
        defer { app.terminate() }
        openLibraryFromHome(in: app)
        openProject("ui-project-001", in: app)
        openInfoAction("detail.export", in: app)
        let exportPrepare = app.buttons["export.prepare"]
        XCTAssertTrue(exportPrepare.waitForExistence(timeout: wait))
        exportPrepare.tap()
        let exportShare = app.buttons["export.share"]
        XCTAssertTrue(exportShare.waitForExistence(timeout: 60))
        capture(app, "slice7-e2e-07-usdz-pdf-head-export-ready")
        let closeExport = app.navigationBars["Export"].buttons["Close"]
        XCTAssertTrue(closeExport.waitForExistence(timeout: shortWait))
        closeExport.tap()
        XCTAssertTrue(exportShare.waitForNonExistence(timeout: wait))
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: shortWait))

        openInfoAction("detail.backup", in: app)
        let backupScroll = app.scrollViews["cloudBackup.scroll"]
        XCTAssertTrue(backupScroll.waitForExistence(timeout: wait))
        tapBackupControl("cloudBackup.check", in: app, scroll: backupScroll)
        XCTAssertTrue(app.staticTexts["cloudBackup.accountStatus"].waitForExistence(timeout: wait))
        tapBackupControl("cloudBackup.list", in: app, scroll: backupScroll)
        XCTAssertTrue(app.staticTexts["cloudBackup.listStatus"].waitForExistence(timeout: wait))
        tapBackupControl("cloudBackup.backup", in: app, scroll: backupScroll)
        let backupRecord = app.buttons["cloudBackup.prepare"]
        XCTAssertTrue(backupRecord.waitForExistence(timeout: wait))
        capture(app, "slice7-e2e-08-fake-backup-completed")
        tapBackupControl("cloudBackup.prepare", in: app, scroll: backupScroll)
        let recoverCopy = app.buttons["cloudBackup.recoverCopy"]
        XCTAssertTrue(recoverCopy.waitForExistence(timeout: wait))
        tapBackupControl("cloudBackup.recoverCopy", in: app, scroll: backupScroll)
        let recovery = element("cloudBackup.recoveryOutcome", in: app)
        XCTAssertTrue(recovery.waitForExistence(timeout: wait))
        XCTAssertTrue(waitForHittable(recovery, in: backupScroll))
        capture(app, "slice7-e2e-09-recovery-copy-outcome")
        attachText("slice7-e2e-recovery-outcome-label", recovery.label)
        closeBackupSheet(in: app)

        tapDetailAction("detail.trash", in: app)
        confirmation("trash.confirm", in: app).tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForNonExistence(timeout: shortWait))
        selectFilter("library.showTrash", in: app)
        openProject("ui-project-001", in: app)
        let banner = element("detail.trashBanner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: shortWait))
        for mutation in ["detail.editRoom", "detail.rescan", "detail.duplicate"] {
            XCTAssertFalse(app.buttons[mutation].exists, "\(mutation) must be absent while trashed.")
        }
        capture(app, "slice7-e2e-10-trashed-detail-banner")

        tapDetailAction("detail.restore", in: app)
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForNonExistence(timeout: shortWait))
        selectFilter("library.showActive", in: app)
        openProject("ui-project-001", in: app)
        XCTAssertTrue(app.buttons["detail.editRoom"].waitForExistence(timeout: shortWait))
        XCTAssertFalse(element("detail.trashBanner", in: app).exists)
        capture(app, "slice7-e2e-11-restored-detail")

        tapDetailAction("detail.trash", in: app)
        confirmation("trash.confirm", in: app).tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForNonExistence(timeout: shortWait))
        selectFilter("library.showTrash", in: app)
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: shortWait))
        capture(app, "slice7-e2e-12-trashed-again")

        openProject("ui-project-001", in: app)
        tapDetailAction("detail.delete", in: app)
        let withBackup = confirmation("delete.confirmWithBackup", in: app)
        XCTAssertEqual(withBackup.label, "Delete now and remove iCloud backup")
        XCTAssertEqual(confirmation("delete.confirm", in: app).label, "Delete now, keep iCloud backup")
        capture(app, "slice7-e2e-13-delete-now-confirmation-with-backup-option")
        withBackup.tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForNonExistence(timeout: shortWait))
        for filter in ["library.showActive", "library.showArchived", "library.showTrash"] {
            selectFilter(filter, in: app)
            XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForNonExistence(timeout: shortWait), filter)
        }
        let outcomeScroll = openBackupSheetFromHome(in: app)
        let outcome = element("cloudBackup.deletionOutcome", in: app)
        XCTAssertTrue(outcome.waitForExistence(timeout: wait))
        XCTAssertTrue(waitForHittable(outcome, in: outcomeScroll))
        XCTAssertTrue(outcome.label.contains("cannot verify physical erasure"), outcome.label)
        XCTAssertFalse(element("cloudBackup.deletionPending", in: app).exists)
        capture(app, "slice7-e2e-14-delete-now-backup-removal-outcome")
        attachText("slice7-e2e-deletion-outcome-label", outcome.label)
        closeBackupSheet(in: app)

        // This launch's deterministic generator handed ui-project-001 to the
        // unused recover-as-copy allocation above, so the next save is 002.
        openMockReview(in: app)
        let secondSave = app.buttons["mockReview.save"]
        scrollIntoView(secondSave, in: app.scrollViews.firstMatch)
        secondSave.tap()
        let secondOpenLibrary = app.buttons["mockReview.openLibrary"]
        XCTAssertTrue(secondOpenLibrary.waitForExistence(timeout: wait))
        scrollIntoView(secondOpenLibrary, in: app.scrollViews.firstMatch, direction: .backward)
        secondOpenLibrary.tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-002"].waitForExistence(timeout: wait))
        openProject("ui-project-002", in: app)
        let trashTime = Int(Date().timeIntervalSince1970)
        tapDetailAction("detail.trash", in: app)
        confirmation("trash.confirm", in: app).tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForNonExistence(timeout: shortWait))
        selectFilter("library.showTrash", in: app)
        XCTAssertTrue(app.buttons["library.project.ui-project-002"].waitForExistence(timeout: shortWait))
        capture(app, "slice7-e2e-15-second-project-trashed")
        app.terminate()

        // Launch 4: the forced clock is 31 days past the second trash time,
        // so foreground reaping must purge ui-project-002.
        let final = launch(token: token, keepRoot: true, extra: ["--trash-clock=\(trashTime + 31 * 86_400)"])
        XCTAssertTrue(final.buttons["home.newRoomScan"].waitForExistence(timeout: wait))
        capture(final, "slice7-e2e-16-relaunch-with-trash-clock")
        attachText("slice7-e2e-final-launch-arguments", final.launchArguments.joined(separator: " "))
        openLibraryFromHome(in: final)
        selectFilter("library.showTrash", in: final)
        XCTAssertTrue(final.buttons["library.project.ui-project-002"].waitForNonExistence(timeout: wait))
        XCTAssertTrue(final.staticTexts["library.empty"].waitForExistence(timeout: wait))
        capture(final, "slice7-e2e-17-purge-observed-empty-trash")
        selectFilter("library.showActive", in: final)
        XCTAssertTrue(final.staticTexts["library.empty"].waitForExistence(timeout: wait))
        XCTAssertEqual(
            final.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.project.")).count, 0
        )
        capture(final, "slice7-e2e-18-no-project-remains")
        final.terminate()
    }

    // MARK: - Exclusive helpers

    private func launch(token: String, keepRoot: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-mock-fixture",
            "--use-fake-cloud-backup",
            "--isolated-root-token=\(token)",
        ]
        if keepRoot {
            app.launchArguments.append("--keep-isolated-root")
        }
        app.launchArguments += extra
        app.launch()
        return app
    }

    /// Names are written literally at each call; this guards the sequence.
    private func capture(_ app: XCUIApplication, _ name: String) {
        let prefix = String(format: "slice7-e2e-%02d-", nextStep)
        XCTAssertTrue(name.hasPrefix(prefix), "Expected step \(prefix), got \(name).")
        nextStep += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private enum Direction { case forward, backward }

    private func scrollIntoView(_ target: XCUIElement, in scrollView: XCUIElement, direction: Direction = .forward) {
        for _ in 0..<12 where !target.isHittable {
            direction == .forward ? scrollView.swipeUp() : scrollView.swipeDown()
        }
        for _ in 0..<12 where !target.isHittable {
            direction == .forward ? scrollView.swipeDown() : scrollView.swipeUp()
        }
    }

    /// `isHittable` is true once any part of a row is on screen, but a switch
    /// row's knob can still sit below the visible edge (seen on a physical
    /// iPhone). Drag slowly until the whole frame is inside the scroll view.
    private func scrollFullyIntoView(_ target: XCUIElement, in scrollView: XCUIElement) {
        scrollIntoView(target, in: scrollView)
        let margin: CGFloat = 24
        for _ in 0..<6 {
            let visible = scrollView.frame
            let frame = target.frame
            let overflow: CGFloat
            if frame.maxY > visible.maxY - margin {
                overflow = frame.maxY - (visible.maxY - margin)
            } else if frame.minY < visible.minY + margin {
                overflow = frame.minY - (visible.minY + margin)
            } else {
                return
            }
            let distance = max(-visible.height / 3, min(visible.height / 3, overflow))
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow,
                        thenHoldForDuration: 0.2)
        }
    }

    private func waitForHittable(_ target: XCUIElement, in scrollView: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var forward = true
        var swipes = 2
        while Date() < deadline {
            for _ in 0..<swipes {
                if target.isHittable { return true }
                guard scrollView.exists else { return false }
                forward ? scrollView.swipeUp() : scrollView.swipeDown()
            }
            forward.toggle()
            swipes = min(swipes + 2, 8)
        }
        return target.isHittable
    }

    private func waitFor(_ target: XCUIElement, _ format: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: target)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// On a physical device the switch value can update after the tap returns;
    /// re-tapping before it settles flips the switch back. Retry only after the
    /// value has demonstrably stayed unchanged.
    private func toggle(_ control: XCUIElement) {
        let original = control.value as? String ?? ""
        let changed = NSPredicate(format: "value != %@", original)
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let first = XCTNSPredicateExpectation(predicate: changed, object: control)
        if XCTWaiter.wait(for: [first], timeout: 5) == .completed { return }
        control.tap()
        let second = XCTNSPredicateExpectation(predicate: changed, object: control)
        _ = XCTWaiter.wait(for: [second], timeout: 5)
    }

    private func openMockReview(in app: XCUIApplication) {
        let newRoomScan = app.buttons["home.newRoomScan"]
        XCTAssertTrue(newRoomScan.waitForExistence(timeout: shortWait))
        let openMockReview = app.buttons["newScan.openMockReview"]
        navigate(newRoomScan, until: openMockReview, in: app)
        navigate(openMockReview, until: app.staticTexts["mockReview.title"], in: app)
    }

    /// A press that lands while Home is still settling after launch can be
    /// dropped without navigating. Press again only while the source control
    /// is still on screen; the destination assertion is unchanged.
    private func navigate(_ source: XCUIElement, until destination: XCUIElement, in app: XCUIApplication) {
        scrollIntoView(source, in: app.scrollViews.firstMatch)
        XCTAssertTrue(source.isHittable, source.identifier)
        source.press(forDuration: 0.15)
        if destination.waitForExistence(timeout: shortWait) { return }
        if source.exists && source.isHittable {
            source.press(forDuration: 0.15)
        }
        XCTAssertTrue(destination.waitForExistence(timeout: wait),
                      "\(source.identifier) did not reach \(destination.identifier).")
    }

    private func openLibraryFromHome(in app: XCUIApplication) {
        let existing = app.buttons["home.existingRooms"]
        XCTAssertTrue(existing.waitForExistence(timeout: wait))
        scrollIntoView(existing, in: app.scrollViews.firstMatch)
        existing.tap()
        XCTAssertTrue(app.buttons["library.showActive"].waitForExistence(timeout: wait))
    }

    private func selectFilter(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: shortWait))
        scrollIntoView(button, in: app.scrollViews.firstMatch, direction: .backward)
        button.tap()
        XCTAssertTrue(waitFor(app.buttons[identifier], "isSelected == true", timeout: shortWait), identifier)
    }

    private func openProject(_ id: String, in app: XCUIApplication) {
        let row = app.buttons["library.project.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: shortWait))
        scrollIntoView(row, in: app.scrollViews.firstMatch)
        row.tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: wait))
        XCTAssertTrue(app.scrollViews["detail.scroll"].waitForExistence(timeout: shortWait))
    }

    private func tapDetailAction(_ identifier: String, in app: XCUIApplication) {
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: shortWait))
        let scroll = app.scrollViews["detail.scroll"]
        scrollIntoView(action, in: scroll)
        if identifier == "detail.trash" || identifier == "detail.delete" {
            scroll.swipeUp() // Expose the whole bottom action, not just its top edge.
        }
        XCTAssertTrue(action.isHittable, identifier)
        action.tap()
    }

    private func openInfoAction(_ identifier: String, in app: XCUIApplication) {
        let toggle = app.buttons["detail.infoToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: shortWait))
        toggle.tap()
        let panel = app.scrollViews["detail.infoPanel.scroll"]
        XCTAssertTrue(panel.waitForExistence(timeout: wait))
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: shortWait))
        scrollIntoView(action, in: panel)
        XCTAssertTrue(action.isHittable, identifier)
        action.tap()
    }

    private func saveOrientation(in app: XCUIApplication) {
        tapDetailAction("detail.reviewOrientation", in: app)
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: shortWait))
        let request = element("orientation.request", in: app)
        scrollIntoView(request, in: form)
        XCTAssertTrue(request.waitForExistence(timeout: shortWait))
        request.tap()
        request.typeText("Synthetic end-to-end brief: keep the captured shell.")
        let save = app.buttons["orientation.save"]
        XCTAssertTrue(save.waitForExistence(timeout: shortWait))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: shortWait))
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: shortWait))
    }

    /// iOS 26 can expose one dialog choice as nested aliases; return one
    /// hittable target and fail if two distinct choices share the identifier.
    private func confirmation(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: identifier)
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: shortWait), identifier)
        let hittable = buttons.allElementsBoundByAccessibilityElement.filter(\.isHittable)
        XCTAssertEqual(Set(hittable.map { "\($0.label)|\($0.frame)" }).count, 1, identifier)
        return hittable.first ?? buttons.firstMatch
    }

    private func tapBackupControl(_ identifier: String, in app: XCUIApplication, scroll: XCUIElement) {
        let control = app.buttons[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: shortWait), identifier)
        XCTAssertTrue(waitForHittable(control, in: scroll), identifier)
        control.tap()
    }

    private func openBackupSheetFromHome(in app: XCUIApplication) -> XCUIElement {
        let settings = app.buttons["home.cloudBackupSettings"]
        for _ in 0..<3 where !settings.exists {
            let back = app.navigationBars.buttons.firstMatch
            guard back.waitForExistence(timeout: shortWait) else { break }
            back.tap()
            _ = settings.waitForExistence(timeout: shortWait)
        }
        XCTAssertTrue(settings.waitForExistence(timeout: shortWait))
        scrollIntoView(settings, in: app.scrollViews.firstMatch)
        settings.tap()
        let scroll = app.scrollViews["cloudBackup.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: wait))
        return scroll
    }

    private func closeBackupSheet(in app: XCUIApplication) {
        let close = app.buttons["cloudBackup.close"]
        XCTAssertTrue(close.waitForExistence(timeout: shortWait))
        close.tap()
        XCTAssertTrue(app.scrollViews["cloudBackup.scroll"].waitForNonExistence(timeout: shortWait))
    }
}
