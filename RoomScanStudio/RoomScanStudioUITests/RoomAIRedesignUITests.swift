import XCTest

/// These tests expect the app launch integration to present
/// `RoomAIRedesignView(model: RoomAIRedesignScreenFixtureModel())` when given
/// `--slice3-ui-fixture`. The fixture has no file picker or network boundary.
final class RoomAIRedesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPackageProfileDisclosureAndShareControls() {
        let app = launchFixture()
        XCTAssertTrue(app.buttons["ai.profile.ready"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "01-light-portrait-profile-brief")
        app.buttons["ai.profile.complete"].tap()
        XCTAssertTrue(app.images["ai.image.north-window.preview"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.switches["ai.complete.rawConsent"].waitForExistence(timeout: 2))
        app.buttons["ai.image.north-window.exclude"].tap()
        XCTAssertTrue(app.buttons["ai.image.north-window.replace"].exists)
        app.buttons["ai.image.north-window.replace"].tap()
        app.buttons["ai.disclosure.refresh"].tap()
        attachScreenshot(app, named: "02-light-portrait-image-review-advisory")
        let providerAcknowledgement = app.switches["ai.provider.acknowledge"]
        scrollForward(providerAcknowledgement, in: app.scrollViews["ai.scroll"])
        toggle(providerAcknowledgement)
        XCTAssertEqual(providerAcknowledgement.value as? String, "1")
        let rawConsent = app.switches["ai.complete.rawConsent"]
        scrollForward(rawConsent, in: app.scrollViews["ai.scroll"])
        toggle(rawConsent)
        XCTAssertEqual(rawConsent.value as? String, "1")
        app.buttons["ai.disclosure.approve"].tap()
        XCTAssertTrue(app.buttons["ai.share"].waitForExistence(timeout: 5))
        scrollForward(app.buttons["ai.share"], in: app.scrollViews["ai.scroll"])
        attachScreenshot(app, named: "03-light-portrait-complete-approved-share")
    }

    func testConceptImportMappingComparisonArchiveAndDeleteConfirmation() {
        let app = launchFixture()
        app.segmentedControls["ai.workspace"].buttons["Concept Sets"].tap()
        XCTAssertTrue(app.buttons["concept.import.loose"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "04-light-portrait-concept-import")
        app.buttons["concept.import.loose"].tap()
        let reopened = app.staticTexts["concept.gallery-reference.mapping"]
        scrollForward(reopened, in: app.scrollViews["concept.scroll"])
        XCTAssertTrue(reopened.exists)
        attachScreenshot(app, named: "05-light-portrait-persisted-packaged-concept")
        let imported = app.buttons["concept.imported-3.mapManual"]
        scrollForward(imported, in: app.scrollViews["concept.scroll"])
        XCTAssertTrue(imported.isHittable)
        imported.tap()
        XCTAssertTrue(app.staticTexts["concept.imported-3.mapping"].label.contains("Manual"))
        attachScreenshot(app, named: "06-light-portrait-manual-mapping")
        app.buttons["concept.imported-3.compare"].tap()
        XCTAssertTrue(app.buttons["concept.comparison.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original room"].exists)
        XCTAssertTrue(app.staticTexts["Imported local reference"].exists)
        attachScreenshot(app, named: "07-light-portrait-original-concept-comparison")
        app.buttons["concept.comparison.done"].tap()
        app.buttons["concept.imported-3.archive"].tap()
        app.buttons["concept.imported-3.delete"].tap()
        XCTAssertTrue(app.buttons["concept.delete.confirm"].waitForExistence(timeout: 2))
        attachScreenshot(app, named: "08-light-portrait-delete-confirmation")
        app.buttons.matching(identifier: "concept.delete.confirm")
            .element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["concept.imported-3.delete"].waitForNonExistence(timeout: 5))
    }

    func testAccessibilityDynamicTypeKeepsCriticalActionsHittable() {
        let app = launchFixture(accessibility: true)
        let prepare = app.buttons["ai.prepare"]
        scrollForward(prepare, in: app.scrollViews["ai.scroll"])
        XCTAssertTrue(prepare.isHittable)
        prepare.tap()
        let approve = app.buttons["ai.disclosure.approve"]
        scrollForward(approve, in: app.scrollViews["ai.scroll"])
        XCTAssertTrue(approve.isHittable)
        attachScreenshot(app, named: "09-accessibility-xxxl-disclosure-actions")
        let conceptTab = app.segmentedControls["ai.workspace"].buttons["Concept Sets"]
        conceptTab.tap()
        let conceptScroll = app.scrollViews["concept.scroll"]
        if !conceptScroll.waitForExistence(timeout: 5) {
            conceptTab.tap()
        }
        XCTAssertTrue(conceptScroll.waitForExistence(timeout: 5))
        let importPackage = app.buttons["concept.import.package"]
        scrollBackward(importPackage, in: conceptScroll)
        XCTAssertTrue(importPackage.isHittable)
        attachScreenshot(app, named: "10-accessibility-xxxl-concept-actions")
    }

    func testDarkModeKeepsProfileAndComparisonReadable() {
        let app = launchFixture(appearance: "Dark")
        XCTAssertTrue(app.buttons["ai.profile.ready"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "11-dark-portrait-profile")

        app.segmentedControls["ai.workspace"].buttons["Concept Sets"].tap()
        let compare = app.buttons["concept.linen-study.compare"]
        scrollForwardPrecisely(compare, in: app.scrollViews["concept.scroll"])
        XCTAssertTrue(compare.isHittable)
        compare.tap()
        XCTAssertTrue(app.buttons["concept.comparison.done"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "12-dark-portrait-comparison")
    }

    func testReadinessFailureIsExplicitAndBlocksPreparation() {
        let app = launchFixture(
            extraArguments: ["--slice3-ui-fixture-readiness-failure"]
        )
        let orientation = app.staticTexts["ai.readiness.orientation"]
        scrollForward(orientation, in: app.scrollViews["ai.scroll"])
        XCTAssertTrue(orientation.label.contains("suggested only"))
        let prepare = app.buttons["ai.prepare"]
        XCTAssertFalse(prepare.isEnabled)
        attachScreenshot(app, named: "13-light-portrait-readiness-failure")
    }

    private func launchFixture(
        accessibility: Bool = false,
        appearance: String? = nil,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-local-store", "--slice3-ui-fixture"]
            + extraArguments
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if let appearance {
            app.launchArguments += ["-AppleInterfaceStyle", appearance]
            if appearance.caseInsensitiveCompare("Dark") == .orderedSame {
                app.launchArguments.append("--slice3-ui-fixture-dark")
            }
        }
        app.launch()
        return app
    }

    private func scrollForward(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<24 where !element.isHittable { scrollView.swipeUp() }
    }

    private func scrollBackward(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<24 where !element.isHittable { scrollView.swipeDown() }
    }

    private func scrollForwardPrecisely(_ element: XCUIElement, in scrollView: XCUIElement) {
        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        for _ in 0..<40 {
            let visibleFrame = scrollView.frame.insetBy(dx: 0, dy: 8)
            let elementCenter = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if element.isHittable, visibleFrame.contains(elementCenter) { break }
            start.press(forDuration: 0.01, thenDragTo: end)
        }
    }

    private func toggle(_ element: XCUIElement) {
        let originalValue = element.value as? String
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if element.value as? String == originalValue {
            element.tap()
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
