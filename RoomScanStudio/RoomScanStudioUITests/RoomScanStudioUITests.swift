import UIKit
import XCTest

final class RoomScanStudioUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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

    func testMetadataDuplicateArchiveUnarchiveAndDeleteRequireExplicitActionsAndConfirmation() {
        executionTimeAllowance = 120
        let app = launchIsolatedApp()
        saveMockRoom(in: app)

        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.buttons["detail.infoToggle"].waitForExistence(timeout: 5))
        app.buttons["detail.infoToggle"].tap()
        XCTAssertTrue(app.buttons["detail.editMetadata"].waitForExistence(timeout: 5))
        app.buttons["detail.editMetadata"].tap()
        XCTAssertTrue(app.textFields["metadata.roomName"].waitForExistence(timeout: 5))
        app.textFields["metadata.roomName"].tap()
        app.textFields["metadata.roomName"].typeText(" Updated")
        app.buttons["metadata.save"].tap()
        let updatedRoomName = app.staticTexts["detail.roomName"]
        XCTAssertTrue(updatedRoomName.waitForExistence(timeout: 5))
        XCTAssertTrue(updatedRoomName.label.contains("Updated"))

        app.buttons["detail.duplicate"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["library.project.ui-project-002"].waitForExistence(timeout: 5))

        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.buttons["detail.infoToggle"].waitForExistence(timeout: 5))
        app.buttons["detail.infoToggle"].tap()
        XCTAssertTrue(app.buttons["detail.archive"].waitForExistence(timeout: 5))
        app.buttons["detail.archive"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["library.showArchived"].tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5))
        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.buttons["detail.infoToggle"].waitForExistence(timeout: 5))
        app.buttons["detail.infoToggle"].tap()
        XCTAssertTrue(app.buttons["detail.unarchive"].waitForExistence(timeout: 5))
        app.buttons["detail.unarchive"].tap()
        // Unarchiving dismisses the info panel; reopen it to confirm the
        // room now offers Archive again, then close it to reach Delete on
        // the base page.
        XCTAssertTrue(app.buttons["detail.infoToggle"].waitForExistence(timeout: 5))
        app.buttons["detail.infoToggle"].tap()
        XCTAssertTrue(app.buttons["detail.archive"].waitForExistence(timeout: 5))
        app.buttons["detail.infoPanel.close"].tap()
        let deleteButton = app.buttons["detail.delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        scrollIntoView(deleteButton, in: app.scrollViews["detail.scroll"])
        deleteButton.tap()
        let deleteConfirmation = app.buttons.matching(identifier: "delete.confirm").firstMatch
        XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 2))
        deleteConfirmation.tap()
        XCTAssertTrue(app.buttons["library.showActive"].waitForExistence(timeout: 2))
        app.buttons["library.showActive"].tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-002"].waitForExistence(timeout: 2))

        app.buttons["library.project.ui-project-002"].tap()
        let duplicateDelete = app.buttons["detail.delete"]
        XCTAssertTrue(duplicateDelete.waitForExistence(timeout: 5))
        let duplicateDetailScroll = app.scrollViews["detail.scroll"]
        XCTAssertTrue(waitForHittable(
            duplicateDelete,
            in: duplicateDetailScroll,
            searchBothDirections: true
        ))
        // `isHittable` can become true when only the top edge is exposed.
        // Move to the scroll limit so the confirmation dialog has a stable
        // presentation anchor instead of a nearly off-screen source view.
        duplicateDetailScroll.swipeUp()
        XCTAssertTrue(duplicateDelete.isHittable)
        duplicateDelete.tap()
        let duplicateDeleteConfirmation = app.buttons.matching(identifier: "delete.confirm").firstMatch
        XCTAssertTrue(duplicateDeleteConfirmation.waitForExistence(timeout: 2))
        duplicateDeleteConfirmation.tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 2))
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
        app.buttons["capture.requestGPS"].tap()
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
        scrollIntoView(list, in: settingsScroll, direction: .backward)
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

    private func launchIsolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-mock-fixture",
        ]
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

    private func openSimulatedCapture(in app: XCUIApplication) {
        app.buttons["home.newRoomScan"].tap()
        XCTAssertTrue(app.buttons["newScan.openCapture"].waitForExistence(timeout: 5))
        app.buttons["newScan.openCapture"].tap()
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
        XCTAssertTrue(newRoomScan.waitForExistence(timeout: 5))
        XCTAssertTrue(newRoomScan.isHittable)
        newRoomScan.tap()

        let mockReview = app.buttons["newScan.openMockReview"]
        XCTAssertTrue(mockReview.waitForExistence(timeout: 5))
        scrollIntoView(mockReview, in: app)
        XCTAssertTrue(mockReview.isHittable)
        mockReview.tap()
        XCTAssertTrue(app.staticTexts["mockReview.title"].waitForExistence(timeout: 2))
    }

    private func saveMockRoom(in app: XCUIApplication) {
        openMockReview(in: app)
        let save = app.buttons["mockReview.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        scrollIntoView(save, in: app)
        XCTAssertTrue(save.isHittable)
        save.tap()

        let openLibrary = app.buttons["mockReview.openLibrary"]
        XCTAssertTrue(openLibrary.waitForExistence(timeout: 5))
        scrollIntoView(openLibrary, in: app, direction: .backward)
        XCTAssertTrue(openLibrary.isHittable)
        openLibrary.tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5))
    }
}
