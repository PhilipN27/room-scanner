import XCTest

/// DEBUG fixture coverage: these launches never construct a hosted client.
final class RoomPublicationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPropertyReviewShowsIndependentRoomDisclaimerAndBoundedControls() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--slice6-publication-ui-fixture",
            "--slice6-publication-ui-property",
            "--slice6-publication-ui-warning",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["publication.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["publication.independentRooms"].exists)
        XCTAssertTrue(app.switches["publication.pin"].exists)
        XCTAssertTrue(app.switches["publication.aiDownload"].exists)
        XCTAssertTrue(app.staticTexts["publication.attribution"].exists)
        attachScreenshot(app, named: "publication-property-warning")
    }

    func testRoomReviewShowsPreparedTitleAndExactPublicRasterCandidates() {
        let app = launchFixture()

        XCTAssertTrue(app.staticTexts["publication.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["publication.preparedTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["publication.raster.floor-plan-north"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["publication.raster.original-north"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["publication.originalAuthority"].exists)
        attachScreenshot(app, named: "publication-room-review")
    }

    func testPendingRevokedFailureAndLinkRecoveryFixturesExposeAccessibleStatus() {
        let pending = launchFixture(["--slice6-publication-ui-pending"])
        XCTAssertTrue(pending.staticTexts["publication.ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(pending.switches["publication.disclosure"].exists)

        let revoked = launchFixture(["--slice6-publication-ui-revoked"])
        XCTAssertTrue(revoked.staticTexts["publication.revoked"].waitForExistence(timeout: 5))
        XCTAssertTrue(revoked.staticTexts["publication.feedbackSummary"].exists)
        XCTAssertTrue(revoked.staticTexts["publication.snapshotUnavailable"].exists)
        XCTAssertFalse(revoked.activityIndicators["publication.preparing"].exists)

        let recovering = launchFixture(["--slice6-publication-ui-link-pending"])
        XCTAssertTrue(recovering.staticTexts["publication.linkPending"].waitForExistence(timeout: 5))
        XCTAssertTrue(recovering.staticTexts["publication.snapshotUnavailable"].exists)
        XCTAssertFalse(recovering.activityIndicators["publication.preparing"].exists)

        let failure = launchFixture(["--slice6-publication-ui-failure"])
        XCTAssertTrue(failure.staticTexts["publication.failure"].waitForExistence(timeout: 5))
        XCTAssertTrue(failure.staticTexts["publication.snapshotUnavailable"].exists)
        XCTAssertFalse(failure.activityIndicators["publication.preparing"].exists)
        let failureMessage = failure.staticTexts["publication.failure"]
        let scroll = failure.scrollViews["publication.scroll"]
        for _ in 0..<16 where !failureMessage.isHittable { scroll.swipeUp() }
        XCTAssertTrue(failureMessage.isHittable, "The failure capture must show the actual recovery status.")
        attachScreenshot(failure, named: "publication-failure")
    }

    private func launchFixture(_ additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--slice6-publication-ui-fixture",
        ] + additionalArguments
        app.launch()
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, named: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = named
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
