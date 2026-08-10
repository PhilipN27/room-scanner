import Foundation
import XCTest
import RoomScanCore
@testable import RoomScanStudio

/// Phase-6 app contracts are authored for the iOS/Xcode gate. They are not
/// executed on this Windows host; the host oracle verifies the source wiring
/// and the Core archive contracts separately.
@MainActor
final class RoomCloudBackupAppTests: XCTestCase {
    func testDisabledAndEnableOnlyChangeLocalPreferenceWithoutCloudCalls() async {
        let provider = FakeCloudBackupProvider()
        let preferences = RoomCloudBackupPreferences(
            isEnabled: false,
            containerIdentifier: "iCloud.org.roomscanstudio.test"
        )
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: preferences
        )

        XCTAssertEqual(coordinator.availability, .disabled)
        XCTAssertEqual(provider.callCount, 0)
        coordinator.setEnabled(true)
        XCTAssertEqual(coordinator.availability, .ready("iCloud.org.roomscanstudio.test"))
        XCTAssertEqual(provider.callCount, 0)
    }

    func testEnabledPreferencePersistsLocallyWithFalseDefaultAndNeverCallsTransport() {
        let suite = "RoomCloudBackupPreferenceTests-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = FakeCloudBackupProvider()
        let first = RoomCloudBackupPreferences(
            isEnabled: nil,
            containerIdentifier: "iCloud.org.roomscanstudio.test",
            defaults: defaults
        )
        XCTAssertFalse(first.isEnabled)
        first.update(isEnabled: true)
        let restored = RoomCloudBackupPreferences(
            isEnabled: nil,
            containerIdentifier: "iCloud.org.roomscanstudio.test",
            defaults: defaults
        )
        _ = RoomCloudBackupCoordinator(provider: provider, preferences: restored)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testCheckIsExplicitAndUsesOnlyAccountOperation() async {
        let provider = FakeCloudBackupProvider()
        let preferences = RoomCloudBackupPreferences(
            isEnabled: true,
            containerIdentifier: "iCloud.org.roomscanstudio.test"
        )
        let coordinator = RoomCloudBackupCoordinator(provider: provider, preferences: preferences)

        await coordinator.checkAccount()

        XCTAssertEqual(provider.accountChecks, ["iCloud.org.roomscanstudio.test"])
        XCTAssertTrue(provider.listRequests.isEmpty)
        XCTAssertTrue(provider.backupRequests.isEmpty)
    }

    func testAccountUnavailableIsPublishedWithoutListingOrUploading() async {
        let provider = FakeCloudBackupProvider()
        provider.accountStatus = .noAccount
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(
                isEnabled: true,
                containerIdentifier: "iCloud.org.roomscanstudio.test"
            )
        )
        await coordinator.checkAccount()
        XCTAssertEqual(coordinator.accountStatus, .noAccount)
        XCTAssertTrue(provider.listRequests.isEmpty)
        XCTAssertTrue(provider.backupRequests.isEmpty)
    }

    func testUnconfiguredAndDisabledOperationsMakeZeroCalls() async {
        let provider = FakeCloudBackupProvider()
        let preferences = RoomCloudBackupPreferences(isEnabled: true, containerIdentifier: "$(CLOUD_CONTAINER)")
        let coordinator = RoomCloudBackupCoordinator(provider: provider, preferences: preferences)

        await coordinator.listBackups()

        XCTAssertEqual(coordinator.availability, .notConfigured)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testListMissingZoneIsEmptyWithoutCreatingZone() async {
        let provider = FakeCloudBackupProvider()
        provider.listResult = .zoneMissing
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(
                isEnabled: true,
                containerIdentifier: "iCloud.org.roomscanstudio.test"
            )
        )

        await coordinator.listBackups()

        XCTAssertEqual(coordinator.backups, [])
        XCTAssertEqual(provider.listRequests.count, 1)
        XCTAssertEqual(provider.zoneCreates, 0)
    }

    func testBackupCreatesZoneAndTreatsSameContentRecordAsIdempotent() async {
        let provider = FakeCloudBackupProvider()
        let descriptor = makeDescriptor(snapshotIDCharacter: "a")
        provider.backupResult = RoomCloudBackupRemoteRecord(descriptor: descriptor)
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(
                isEnabled: true,
                containerIdentifier: "iCloud.org.roomscanstudio.test"
            )
        )

        await coordinator.backUp(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        await coordinator.backUp(projectID: "project-001", expectedHeadRevisionID: "revision-001")

        XCTAssertEqual(provider.backupRequests.count, 2)
        XCTAssertEqual(provider.zoneCreates, 2)
        XCTAssertEqual(coordinator.backups.map(\.descriptor.snapshotID), [descriptor.snapshotID])
    }

    func testTransientFailureRetriesButLimitExceededDoesNotRetry() async {
        let transientProvider = FakeCloudBackupProvider()
        transientProvider.backupErrors = [
            .serviceUnavailable(retryAfterSeconds: 0),
            .networkUnavailable(retryAfterSeconds: 0),
        ]
        transientProvider.backupResult = RoomCloudBackupRemoteRecord(
            descriptor: makeDescriptor(snapshotIDCharacter: "b")
        )
        let transientCoordinator = RoomCloudBackupCoordinator(
            provider: transientProvider,
            preferences: RoomCloudBackupPreferences(isEnabled: true, containerIdentifier: "iCloud.org.roomscanstudio.test"),
            sleeper: ImmediateCloudBackupSleeper()
        )

        await transientCoordinator.backUp(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        XCTAssertEqual(transientProvider.backupRequests.count, 3)

        let limitProvider = FakeCloudBackupProvider()
        limitProvider.backupErrors = [.limitExceeded]
        let limitCoordinator = RoomCloudBackupCoordinator(
            provider: limitProvider,
            preferences: RoomCloudBackupPreferences(isEnabled: true, containerIdentifier: "iCloud.org.roomscanstudio.test"),
            sleeper: ImmediateCloudBackupSleeper()
        )
        await limitCoordinator.backUp(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        XCTAssertEqual(limitProvider.backupRequests.count, 1)
        XCTAssertNotNil(limitCoordinator.errorMessage)
    }

    func testCoordinatorForwardsRecoveryAndCancelCleansExactPreparedLease() async {
        let provider = FakeCloudBackupProvider()
        let record = RoomCloudBackupRemoteRecord(descriptor: makeDescriptor(snapshotIDCharacter: "c"))
        let prepared = RoomCloudBackupPreparedRecovery(token: "prepared-001", record: record)
        provider.preparedRecovery = prepared
        provider.recoveryResult = .recoveredCopy(makeSummary(projectID: "recovered-copy-001"))
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(isEnabled: true, containerIdentifier: "iCloud.org.roomscanstudio.test")
        )

        await coordinator.prepareRecovery(record: record)
        XCTAssertEqual(coordinator.preparedRecovery, prepared)
        await coordinator.cancelPreparedRecovery()
        XCTAssertEqual(provider.cancelledRecoveryTokens, ["prepared-001"])

        await coordinator.prepareRecovery(record: record)
        await coordinator.commitPreparedRecovery(asCopy: true)
        XCTAssertEqual(provider.committedRecoveryTokens, ["prepared-001"])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testRecoveryConflictCanProceedToExplicitCopyAndCleanupRetryRemainsActionable() async {
        let provider = FakeCloudBackupProvider()
        let record = RoomCloudBackupRemoteRecord(descriptor: makeDescriptor(snapshotIDCharacter: "e"))
        let prepared = RoomCloudBackupPreparedRecovery(token: "prepared-conflict", record: record)
        provider.preparedRecovery = prepared
        provider.commitErrors = [RoomBackupError.recoveryConflict("project-001")]
        provider.recoveryResult = .recoveredCopy(makeSummary(projectID: "recovered-copy-001"))
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(isEnabled: true, containerIdentifier: "iCloud.org.roomscanstudio.test")
        )

        await coordinator.prepareRecovery(record: record)
        await coordinator.commitPreparedRecovery(asCopy: false)
        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertNotNil(coordinator.preparedRecovery)

        // The user can choose the explicit copy policy without relaunching or
        // silently overwriting the divergent project.
        coordinator.clearError()
        await coordinator.commitPreparedRecovery(asCopy: true)
        XCTAssertEqual(provider.copyRecoveryRequests, 1)
        XCTAssertEqual(coordinator.state, .idle)

        provider.cleanupFailuresRemaining = 1
        await coordinator.prepareRecovery(record: record)
        await coordinator.cancelPreparedRecovery()
        XCTAssertEqual(coordinator.state, .cleanupFailed)
        XCTAssertNotNil(coordinator.preparedRecovery)
        await coordinator.retryCleanup()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.preparedRecovery)
        XCTAssertGreaterThanOrEqual(provider.cleanupRetries, 1)
    }

    func testBoundedCloudListingPublishesTruncationInsteadOfRetainingUnboundedRecords() async {
        let provider = FakeCloudBackupProvider()
        let records = (0..<(RoomCloudBackupListedRecords.maximumRecords + 1)).map { index in
            RoomCloudBackupRemoteRecord(descriptor: makeDescriptor(snapshotIDCharacter: index.isMultiple(of: 2) ? "a" : "b", suffix: index))
        }
        provider.listResult = .backups(RoomCloudBackupListedRecords(records: records))
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(
                isEnabled: true,
                containerIdentifier: "iCloud.org.roomscanstudio.test"
            )
        )

        await coordinator.listBackups()

        XCTAssertEqual(coordinator.backups.count, RoomCloudBackupListedRecords.maximumRecords)
        XCTAssertTrue(coordinator.backupsAreTruncated)
    }

    func testMalformedSuccessfulDescriptorsAreSkippedWhileValidBackupsRemainAvailable() async {
        let provider = FakeCloudBackupProvider()
        let valid = RoomCloudBackupRemoteRecord(descriptor: makeDescriptor(snapshotIDCharacter: "f"))
        provider.listResult = .backups(RoomCloudBackupListedRecords(
            records: [valid],
            skippedMalformedRecordCount: 2
        ))
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(
                isEnabled: true,
                containerIdentifier: "iCloud.org.roomscanstudio.test"
            )
        )

        await coordinator.listBackups()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.backups, [valid])
        XCTAssertEqual(coordinator.skippedMalformedBackupRecordCount, 2)
        XCTAssertNil(coordinator.errorMessage)

        // The count has a bounded representation: malformed successful
        // descriptors cannot cause an unbounded list scan or UI payload.
        let capped = RoomCloudBackupListedRecords(
            records: [valid],
            skippedMalformedRecordCount: RoomCloudBackupListedRecords.maximumSkippedMalformedRecords + 1
        )
        XCTAssertEqual(
            capped.skippedMalformedRecordCount,
            RoomCloudBackupListedRecords.maximumSkippedMalformedRecords
        )
        XCTAssertTrue(capped.isTruncated)
    }

    func testListingAccumulatorStopsPagingOnceTheValidRecordCapIsReached() {
        var accumulator = RoomCloudBackupListingAccumulator()
        let page = (0..<RoomCloudBackupListedRecords.maximumRecords).map { index in
            RoomCloudBackupRemoteRecord(
                descriptor: makeDescriptor(snapshotIDCharacter: "c", suffix: index)
            )
        }

        accumulator.append(
            records: page,
            skippedMalformedRecordCount: 0,
            hasMorePages: true
        )

        XCTAssertEqual(accumulator.listing.records.count, RoomCloudBackupListedRecords.maximumRecords)
        XCTAssertTrue(accumulator.listing.isTruncated)
        XCTAssertFalse(accumulator.shouldRequestNextPage)
    }

    func testListTransportFailurePreservesPriorValidListingAndPublishesFailure() async {
        let provider = FakeCloudBackupProvider()
        let valid = RoomCloudBackupRemoteRecord(descriptor: makeDescriptor(snapshotIDCharacter: "9"))
        provider.listResult = .backups(RoomCloudBackupListedRecords(
            records: [valid],
            skippedMalformedRecordCount: 1
        ))
        let coordinator = RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(
                isEnabled: true,
                containerIdentifier: "iCloud.org.roomscanstudio.test"
            )
        )

        await coordinator.listBackups()
        provider.listErrors = [.accountUnavailable]
        await coordinator.listBackups()

        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertEqual(coordinator.backups, [valid])
        XCTAssertEqual(coordinator.skippedMalformedBackupRecordCount, 1)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    private func makeDescriptor(snapshotIDCharacter: Character, suffix: Int = 0) -> RoomCloudBackupDescriptor {
        let prefix = String(format: "%02x", suffix % 256)
        let hash = (prefix + String(repeating: String(snapshotIDCharacter), count: 64)).prefix(64)
        return RoomCloudBackupDescriptor(
            snapshotID: String(hash),
            projectID: "project-001",
            headRevisionID: "revision-001",
            projectSchemaVersion: "roomscan-project-v2",
            displayName: "Backup room",
            sourceUpdatedAt: Date(timeIntervalSince1970: 1_704_067_200),
            revisionCount: 1,
            fileCount: 7,
            uncompressedByteCount: 256,
            manifestSHA256: String(hash),
            archiveSHA256: String(repeating: "d", count: 64),
            archiveByteCount: 512
        )
    }

    private func makeSummary(projectID: String) -> RoomProjectSummary {
        RoomProjectSummary(
            projectID: projectID,
            customName: "Recovered Copy",
            captureDate: Date(timeIntervalSince1970: 1_704_067_200),
            lastRevisedDate: Date(timeIntervalSince1970: 1_704_067_200),
            manualLocation: "",
            tags: [],
            thumbnailRelativePath: nil,
            archived: false,
            headRevisionID: "revision-001"
        )
    }
}

@MainActor
private final class FakeCloudBackupProvider: RoomCloudBackupProviding {
    var accountStatus: RoomCloudBackupAccountStatus = .available
    var listResult: RoomCloudBackupListResult = .backups(RoomCloudBackupListedRecords(records: []))
    var listErrors: [RoomCloudBackupTransportError] = []
    var backupResult: RoomCloudBackupRemoteRecord?
    var backupErrors: [RoomCloudBackupTransportError] = []
    var preparedRecovery: RoomCloudBackupPreparedRecovery?
    var recoveryResult: RoomBackupRecoveryResult = .noOp
    var commitErrors: [Error] = []
    var cleanupFailuresRemaining = 0
    private(set) var accountChecks: [String] = []
    private(set) var listRequests: [String] = []
    private(set) var backupRequests: [(String, String)] = []
    private(set) var zoneCreates = 0
    private(set) var cancelledRecoveryTokens: [String] = []
    private(set) var committedRecoveryTokens: [String] = []
    private(set) var copyRecoveryRequests = 0
    private(set) var cleanupRetries = 0

    var callCount: Int { accountChecks.count + listRequests.count + backupRequests.count + zoneCreates }

    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus {
        accountChecks.append(containerIdentifier)
        return accountStatus
    }

    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult {
        listRequests.append(containerIdentifier)
        if !listErrors.isEmpty {
            throw listErrors.removeFirst()
        }
        return listResult
    }

    func backUp(projectID: String, expectedHeadRevisionID: String, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord {
        zoneCreates += 1
        backupRequests.append((projectID, expectedHeadRevisionID))
        if !backupErrors.isEmpty {
            throw backupErrors.removeFirst()
        }
        return try XCTUnwrap(backupResult)
    }

    func prepareRecovery(record: RoomCloudBackupRemoteRecord, containerIdentifier: String) async throws -> RoomCloudBackupPreparedRecovery {
        _ = containerIdentifier
        return try XCTUnwrap(preparedRecovery)
    }

    func commitPreparedRecovery(_ preparation: RoomCloudBackupPreparedRecovery, asCopy: Bool) async throws -> RoomBackupRecoveryResult {
        if !commitErrors.isEmpty { throw commitErrors.removeFirst() }
        if asCopy { copyRecoveryRequests += 1 }
        committedRecoveryTokens.append(preparation.token)
        return recoveryResult
    }

    func discardPreparedRecovery(_ preparation: RoomCloudBackupPreparedRecovery) async throws {
        cancelledRecoveryTokens.append(preparation.token)
        if cleanupFailuresRemaining > 0 {
            cleanupFailuresRemaining -= 1
            throw RoomCloudBackupLeaseCleanupError(
                workspaceURL: URL(fileURLWithPath: "/test-cleanup"),
                message: "Injected cleanup failure."
            )
        }
    }

    func retryCleanup() async throws -> Bool {
        cleanupRetries += 1
        if cleanupFailuresRemaining > 0 {
            cleanupFailuresRemaining -= 1
            throw RoomCloudBackupLeaseCleanupError(
                workspaceURL: URL(fileURLWithPath: "/test-cleanup"),
                message: "Injected cleanup retry failure."
            )
        }
        return true
    }
}
