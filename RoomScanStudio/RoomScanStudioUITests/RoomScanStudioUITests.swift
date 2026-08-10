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
        XCTAssertTrue(existingRooms.waitForExistence(timeout: 5))
        XCTAssertTrue(newRoomScan.waitForExistence(timeout: 5))
        scrollIntoView(existingRooms, in: app)
        XCTAssertTrue(existingRooms.isHittable)
        scrollIntoView(newRoomScan, in: app)
        XCTAssertTrue(newRoomScan.isHittable)

        newRoomScan.tap()
        let mockReview = app.buttons["newScan.openMockReview"]
        XCTAssertTrue(mockReview.waitForExistence(timeout: 5))
        scrollIntoView(mockReview, in: app)
        XCTAssertTrue(mockReview.isHittable)
        mockReview.tap()

        let save = app.buttons["mockReview.save"]
        let discard = app.buttons["mockReview.discard"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        scrollIntoView(save, in: app)
        XCTAssertTrue(save.isHittable)
        scrollIntoView(discard, in: app)
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
        let saveApp = launchIsolatedApp()
        openMockReview(in: saveApp)
        saveApp.buttons["mockReview.save"].tap()
        XCTAssertTrue(saveApp.buttons["mockReview.openLibrary"].waitForExistence(timeout: 2))
        saveApp.buttons["mockReview.openLibrary"].tap()
        XCTAssertTrue(saveApp.buttons["library.project.ui-project-001"].waitForExistence(timeout: 2))

        let discardApp = launchIsolatedApp()
        openMockReview(in: discardApp)
        discardApp.buttons["mockReview.discard"].tap()
        XCTAssertTrue(discardApp.buttons["home.existingRooms"].waitForExistence(timeout: 2))
        discardApp.buttons["home.existingRooms"].tap()
        XCTAssertTrue(discardApp.staticTexts["library.empty"].waitForExistence(timeout: 2))
    }

    func testMetadataDuplicateArchiveUnarchiveAndDeleteRequireExplicitActionsAndConfirmation() {
        let app = launchIsolatedApp()
        saveMockRoom(in: app)

        app.buttons["library.project.ui-project-001"].tap()
        app.buttons["detail.editMetadata"].tap()
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
        app.buttons["detail.archive"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["library.showArchived"].tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 5))
        app.buttons["library.project.ui-project-001"].tap()
        app.buttons["detail.unarchive"].tap()
        XCTAssertTrue(app.buttons["detail.archive"].waitForExistence(timeout: 5))
        app.buttons["detail.delete"].tap()
        let deleteConfirmation = app.buttons.matching(identifier: "delete.confirm").firstMatch
        XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 2))
        deleteConfirmation.tap()
        XCTAssertTrue(app.buttons["library.showActive"].waitForExistence(timeout: 2))
        app.buttons["library.showActive"].tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-002"].waitForExistence(timeout: 2))

        app.buttons["library.project.ui-project-002"].tap()
        app.buttons["detail.delete"].tap()
        let duplicateDeleteConfirmation = app.buttons.matching(identifier: "delete.confirm").firstMatch
        XCTAssertTrue(duplicateDeleteConfirmation.waitForExistence(timeout: 2))
        duplicateDeleteConfirmation.tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 2))
    }

    func testRevisionInspectionAndRestoreCreateNewLineage() {
        let app = launchIsolatedApp()
        saveMockRoom(in: app)

        app.buttons["library.project.ui-project-001"].tap()
        let revisionOne = app.buttons["revision.revision-001"]
        scrollIntoView(revisionOne, in: app)
        XCTAssertTrue(revisionOne.isHittable)
        revisionOne.tap()
        XCTAssertTrue(app.staticTexts["revision.inspect.revision-001"].waitForExistence(timeout: 2))
        app.buttons["revision.restore.revision-001"].tap()
        let headRevision = app.staticTexts["detail.headRevision"]
        XCTAssertTrue(waitForLabel(headRevision, equals: "revision-002", timeout: 5))
        XCTAssertEqual(headRevision.label, "revision-002")
        let revisionTwo = app.buttons["revision.revision-002"]
        scrollIntoView(revisionTwo, in: app)
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
        app.buttons["detail.rescan"].tap()
        XCTAssertTrue(app.staticTexts["rescan.preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["rescan.status"].waitForExistence(timeout: 5))
        app.buttons["rescan.undo"].tap()
        XCTAssertTrue(app.staticTexts["detail.headRevision"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.headRevision"].label, "revision-001")

        app.buttons["detail.rescan"].tap()
        XCTAssertTrue(app.buttons["rescan.accept"].waitForExistence(timeout: 5))
        app.buttons["rescan.accept"].tap()
        XCTAssertTrue(app.staticTexts["rescan.accepted"].waitForExistence(timeout: 5))
        app.buttons["rescan.done"].tap()
        let headRevision = app.staticTexts["detail.headRevision"]
        XCTAssertTrue(waitForLabel(headRevision, equals: "revision-002", timeout: 5))
        let revisionTwo = app.buttons["revision.revision-002"]
        scrollIntoView(revisionTwo, in: app)
        XCTAssertTrue(revisionTwo.isHittable)

        let revisionOne = app.buttons["revision.revision-001"]
        scrollIntoView(revisionOne, in: app)
        XCTAssertTrue(revisionOne.isHittable)
        revisionOne.tap()
        XCTAssertTrue(app.buttons["revision.restore.revision-001"].waitForExistence(timeout: 5))
        app.buttons["revision.restore.revision-001"].tap()
        XCTAssertTrue(waitForLabel(headRevision, equals: "revision-003", timeout: 5))
        let revisionThree = app.buttons["revision.revision-003"]
        scrollIntoView(revisionThree, in: app, direction: .backward)
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
        XCTAssertTrue(app.switches["viewer.visibility.structural"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["viewer.visibility.objects"].waitForExistence(timeout: 5))
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
        XCTAssertEqual(persistedLabel.label, "Main floor Edited")
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
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        scrollIntoView(error, in: settingsScroll)
        XCTAssertTrue(error.isHittable)
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
        XCTAssertTrue(notConfigured.waitForExistence(timeout: 5))
        scrollIntoView(notConfigured, in: settingsScroll)
        XCTAssertTrue(notConfigured.isHittable)
        XCTAssertFalse(app.links["settings.privacyPolicyLink"].exists)
    }

    func testFakeCloudBackupRequiresExplicitListBackupAndRecoverCopyAction() {
        let app = launchFakeCloudBackupApp()
        saveMockRoom(in: app)
        app.buttons["library.project.ui-project-001"].tap()
        XCTAssertTrue(app.staticTexts["detail.roomName"].waitForExistence(timeout: 5))
        let detailBackup = app.buttons["detail.backup"]
        XCTAssertTrue(detailBackup.waitForExistence(timeout: 5))
        scrollIntoView(detailBackup, in: app)
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
        scrollIntoView(accountStatus, in: settingsScroll)
        XCTAssertTrue(accountStatus.isHittable)
        let list = app.buttons["cloudBackup.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        scrollIntoView(list, in: settingsScroll, direction: .backward)
        XCTAssertTrue(list.isHittable)
        list.tap()
        let backup = app.buttons["cloudBackup.backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        scrollIntoView(backup, in: settingsScroll)
        XCTAssertTrue(backup.isHittable)
        backup.tap()
        XCTAssertTrue(app.buttons["cloudBackup.prepare"].waitForExistence(timeout: 5))
        let prepare = app.buttons["cloudBackup.prepare"]
        scrollIntoView(prepare, in: settingsScroll)
        XCTAssertTrue(prepare.isHittable)
        prepare.tap()
        let recoverCopy = app.buttons["cloudBackup.recoverCopy"]
        XCTAssertTrue(recoverCopy.waitForExistence(timeout: 5))
        scrollIntoView(recoverCopy, in: settingsScroll)
        XCTAssertTrue(recoverCopy.isHittable)
        recoverCopy.tap()
        XCTAssertTrue(app.staticTexts["cloudBackup.recoveryOutcome"].waitForExistence(timeout: 5))
        let outcome = app.staticTexts["cloudBackup.recoveryOutcome"]
        scrollIntoView(outcome, in: settingsScroll)
        XCTAssertTrue(outcome.isHittable)
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
        XCTAssertTrue(accountStatus.waitForExistence(timeout: 5))
        scrollIntoView(accountStatus, in: settingsScroll)
        XCTAssertTrue(accountStatus.isHittable)
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
        for _ in 0..<6 where !element.isHittable {
            switch direction {
            case .forward:
                scrollView.swipeUp()
            case .backward:
                scrollView.swipeDown()
            }
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
        app.buttons["home.newRoomScan"].tap()
        app.buttons["newScan.openMockReview"].tap()
        XCTAssertTrue(app.staticTexts["mockReview.title"].waitForExistence(timeout: 2))
    }

    private func saveMockRoom(in app: XCUIApplication) {
        openMockReview(in: app)
        app.buttons["mockReview.save"].tap()
        XCTAssertTrue(app.buttons["mockReview.openLibrary"].waitForExistence(timeout: 2))
        app.buttons["mockReview.openLibrary"].tap()
        XCTAssertTrue(app.buttons["library.project.ui-project-001"].waitForExistence(timeout: 2))
    }
}
