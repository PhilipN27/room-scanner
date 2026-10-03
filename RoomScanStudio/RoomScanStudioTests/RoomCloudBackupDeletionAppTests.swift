import Combine
import Foundation
import RoomScanCore
import XCTest
@testable import RoomScanStudio

/// Simulator app-layer proofs for private backup deletion. Every transport is
/// a deterministic fake or spy; nothing here contacts CloudKit.
@MainActor
final class RoomCloudBackupDeletionAppTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryRoot: URL!
    private let epoch = Date(timeIntervalSince1970: 1_800_014_400)
    private let container = "iCloud.org.roomscanstudio.test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RoomCloudBackupDeletionAppTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try fileManager.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Fake transport (VAL-BACKUP-005, -006, -017)

    func testFakeTransportTreatsMissingRecordsAndMissingZoneAsDeleted() async throws {
        let neverCreated = DeterministicCloudBackupTransport()
        let names = [recordName("a"), recordName("b")]
        let zoneMissing = try await neverCreated.deleteBackups(
            projectID: "ui-project-001", knownRecordNames: names, containerIdentifier: container
        )
        XCTAssertEqual(zoneMissing.remainingRecordNames, [])
        XCTAssertEqual(zoneMissing.failures, [:])
        XCTAssertEqual(zoneMissing.deletedRecordNames, names)
        let listing = try await neverCreated.listBackups(containerIdentifier: container)
        XCTAssertEqual(listing, .zoneMissing, "Deleting must not create the zone.")

        let seeded = try seededTransport(descriptors: [descriptor("c")])
        let missing = try await seeded.deleteBackups(
            projectID: "ui-project-001", knownRecordNames: names, containerIdentifier: container
        )
        XCTAssertEqual(missing.remainingRecordNames, [])
        XCTAssertEqual(missing.failures, [:])
        XCTAssertEqual(missing.deletedRecordNames, names + [recordName("c")])
        attach("VAL-BACKUP-005", "fake-missing-zone-and-records",
               "Zone missing: \(zoneMissing). Known-but-absent records: \(missing). No throw, nothing remaining.")
    }

    func testFakeTransportPartialFailureSeamAndDeleteErrorsFIFOReportHonestly() async throws {
        let transport = try seededTransport(descriptors: [descriptor("a"), descriptor("b"), descriptor("c")])
        transport.partialDeleteFailureCount = 1
        let partial = try await transport.deleteBackups(
            projectID: "ui-project-001", knownRecordNames: [], containerIdentifier: container
        )
        XCTAssertEqual(partial.deletedRecordNames, [recordName("a"), recordName("b")])
        XCTAssertEqual(partial.remainingRecordNames, [recordName("c")])
        XCTAssertEqual(Array(partial.failures.keys), [recordName("c")])
        let listedAfterPartial = try await listedNames(transport)
        XCTAssertEqual(listedAfterPartial, [recordName("c")])

        let fifo = try seededTransport(descriptors: [descriptor("d")])
        fifo.deleteErrors = [.networkUnavailable(retryAfterSeconds: nil)]
        do {
            _ = try await fifo.deleteBackups(projectID: "ui-project-001", knownRecordNames: [], containerIdentifier: container)
            XCTFail("The queued delete error must throw once.")
        } catch let error as RoomCloudBackupTransportError {
            XCTAssertEqual(error, .networkUnavailable(retryAfterSeconds: nil))
        }
        let listedAfterThrow = try await listedNames(fifo)
        XCTAssertEqual(listedAfterThrow, [recordName("d")], "A thrown delete removes nothing.")
        let second = try await fifo.deleteBackups(
            projectID: "ui-project-001", knownRecordNames: [], containerIdentifier: container
        )
        XCTAssertEqual(second.deletedRecordNames, [recordName("d")])
        XCTAssertTrue(second.isComplete)
        let listedAfterRetry = try await listedNames(fifo)
        XCTAssertEqual(listedAfterRetry, [])
        attach("VAL-BACKUP-006", "fake-partial-and-fifo",
               "Partial (fail 1 of 3): \(partial). FIFO: first call threw networkUnavailable, second: \(second).")
    }

    func testFakeRecordsPersistOnlyWithAPersistenceRoot() async throws {
        let root = temporaryRoot.appendingPathComponent("RoomScanStudio-UI-Testing-FakeCloudBackup-token", isDirectory: true)
        let first = try seededTransport(descriptors: [descriptor("a"), descriptor("b")], root: root)
        let recordsURL = try XCTUnwrap(first.persistedRecordsURL)
        _ = try await first.deleteBackupRecords(named: [recordName("a")], containerIdentifier: container)
        let reloaded = DeterministicCloudBackupTransport(persistenceRootURL: root)
        let reloadedListing = try await listedNames(reloaded)
        XCTAssertEqual(reloadedListing, [recordName("b")])
        let bytes = try Data(contentsOf: recordsURL)
        XCTAssertNotNil(String(data: bytes, encoding: .utf8)?.range(of: "\"zoneExists\":true"))

        let memoryOnly = DeterministicCloudBackupTransport()
        XCTAssertNil(memoryOnly.persistedRecordsURL)
        try await memoryOnly.ensureBackupZone(containerIdentifier: container)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: temporaryRoot.path), [root.lastPathComponent])
        attach("VAL-BACKUP-017", "fake-token-persistence",
               "records.json present after delete under token root; reloaded listing \(storedNames(reloaded)). "
               + "In-memory transport has no persistence URL and wrote no file.")
    }

    // MARK: - Launch arguments (VAL-BACKUP-016)

    func testFakeDeleteFailureArgumentIsHonoredOnlyInIsolatedFakeRuns() {
        let fake = CloudBackupFakeTransportFactory.make(
            arguments: ["--ui-testing", "--use-fake-cloud-backup", "--fake-cloud-delete-fails-once"],
            fileManager: fileManager
        )
        XCTAssertEqual(fake?.deleteErrors, [.networkUnavailable(retryAfterSeconds: nil)])
        XCTAssertNil(fake?.persistedRecordsURL, "Without a token the fake stays in memory.")
        XCTAssertEqual(
            CloudBackupFakeTransportFactory.make(
                arguments: ["--ui-testing", "--use-fake-cloud-backup"], fileManager: fileManager
            )?.deleteErrors,
            []
        )
        for arguments in [
            ["--use-fake-cloud-backup", "--fake-cloud-delete-fails-once"],
            ["--ui-testing", "--fake-cloud-delete-fails-once"],
            ["--fake-cloud-delete-fails-once"],
        ] {
            XCTAssertNil(CloudBackupFakeTransportFactory.make(arguments: arguments, fileManager: fileManager),
                         "\(arguments) must keep the production transport.")
        }
        XCTAssertEqual(
            CloudBackupContainerArgument.resolve(arguments: ["--use-fake-cloud-backup"], buildContainerIdentifier: ""),
            "",
            "The fake container fallback also requires --ui-testing."
        )
        attach("VAL-BACKUP-016", "fake-delete-argument-gating",
               "--fake-cloud-delete-fails-once queues one networkUnavailable only with --ui-testing and "
               + "--use-fake-cloud-backup; any missing gate creates no fake transport. "
               + "--fake-cloud-seeded-backups is not implemented (not applicable).")
    }

    // MARK: - Journal (VAL-BACKUP-007, -008, -012)

    func testJournalWritesOwnershipMarkerAndCanonicalRecordsOutsideProjects() throws {
        let root = temporaryRoot.appendingPathComponent("CloudBackupDeletionJournal", isDirectory: true)
        let journal = RoomCloudBackupDeletionJournal(rootURL: root)
        XCTAssertEqual(try journal.pendingRequests(), [])
        XCTAssertFalse(fileManager.fileExists(atPath: root.path), "Reading an absent journal creates nothing.")

        let request = makeRequest("ui-project-001", knownRecordNames: [recordName("a")])
        try journal.replace(request)
        let markerData = try Data(contentsOf: root.appendingPathComponent(RoomCloudBackupDeletionJournal.markerFilename))
        let marker = try JSONDecoder().decode(RoomCloudBackupDeletionJournal.Marker.self, from: markerData)
        XCTAssertEqual(marker.schemaVersion, RoomCloudBackupDeletionJournal.schemaVersion)
        XCTAssertNotNil(UUID(uuidString: marker.ownershipToken))
        let recordURL = root.appendingPathComponent("records/ui-project-001.json")
        let bytes = try Data(contentsOf: recordURL)
        XCTAssertEqual(bytes, try RoomCloudBackupDeletionJournal.canonicalData(for: request))
        let decoded = try JSONDecoder().decode(RoomCloudBackupDeletionRequest.self, from: bytes)
        XCTAssertEqual(try RoomCloudBackupDeletionJournal.canonicalData(for: decoded), bytes)
        XCTAssertEqual(try journal.load(projectID: "ui-project-001"), request)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: root.appendingPathComponent("records").path),
            ["ui-project-001.json"],
            "Stage files must not survive a successful replace."
        )

        let production = RoomCloudBackupDeletionJournalRootResolver.resolve(arguments: [], fileManager: fileManager)
        XCTAssertTrue(production.path.hasSuffix("Application Support/RoomScanStudio/CloudBackupDeletionJournal"))
        XCTAssertFalse(production.pathComponents.contains("Projects"))
        let isolatedArguments = ["--ui-testing", "--reset-local-store", "--isolated-root-token=journal-check", "--keep-isolated-root"]
        let isolated = RoomCloudBackupDeletionJournalRootResolver.resolve(arguments: isolatedArguments, fileManager: fileManager)
        let projects = RoomProjectRootResolver.resolve(arguments: isolatedArguments, fileManager: fileManager)
        XCTAssertEqual(isolated.deletingLastPathComponent(), projects.deletingLastPathComponent())
        XCTAssertEqual(isolated.lastPathComponent, "RoomScanStudio-UI-Testing-CloudBackupDeletionJournal-journal-check")
        attach("VAL-BACKUP-007", "journal-marker-and-canonical-record",
               "Marker \(marker.schemaVersion) with UUID token; record bytes equal canonical encoder output; "
               + "production root …/\(production.pathComponents.suffix(3).joined(separator: "/")); "
               + "isolated root \(isolated.lastPathComponent) beside \(projects.lastPathComponent).")
    }

    func testJournalRejectsUnsafeIdentifiersSymlinksAndNonRegularFiles() throws {
        let root = temporaryRoot.appendingPathComponent("Journal", isDirectory: true)
        let journal = RoomCloudBackupDeletionJournal(rootURL: root)
        for unsafe in ["", "a/b", "..", "../escape"] {
            XCTAssertThrowsError(try journal.load(projectID: unsafe), "load \(unsafe)")
            XCTAssertThrowsError(try journal.remove(projectID: unsafe), "remove \(unsafe)")
            var request = makeRequest("ui-project-001")
            request.projectID = unsafe
            XCTAssertThrowsError(try journal.replace(request), "replace \(unsafe)")
        }

        try journal.replace(makeRequest("ui-project-001"))
        let canary = temporaryRoot.appendingPathComponent("canary.json")
        let canaryBytes = Data("synthetic canary".utf8)
        try canaryBytes.write(to: canary)
        let linked = root.appendingPathComponent("records/linked.json")
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: canary)
        XCTAssertThrowsError(try journal.load(projectID: "linked"))
        XCTAssertThrowsError(try journal.replace(makeRequest("linked")))
        XCTAssertThrowsError(try journal.pendingRequests())
        XCTAssertEqual(try Data(contentsOf: canary), canaryBytes, "The symlink target is untouched.")
        try fileManager.removeItem(at: linked)

        let directoryRecord = root.appendingPathComponent("records/as-directory.json", isDirectory: true)
        try fileManager.createDirectory(at: directoryRecord, withIntermediateDirectories: false)
        XCTAssertThrowsError(try journal.load(projectID: "as-directory"))
        try fileManager.removeItem(at: directoryRecord)

        let realParent = temporaryRoot.appendingPathComponent("RealParent", isDirectory: true)
        try fileManager.createDirectory(at: realParent, withIntermediateDirectories: false)
        let linkedParent = temporaryRoot.appendingPathComponent("LinkedParent", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        let ancestorJournal = RoomCloudBackupDeletionJournal(
            rootURL: linkedParent.appendingPathComponent("Journal", isDirectory: true)
        )
        XCTAssertThrowsError(try ancestorJournal.replace(makeRequest("ui-project-001")))
        XCTAssertThrowsError(try ancestorJournal.pendingRequests())
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: realParent.path), [])

        let markerDirectoryRoot = temporaryRoot.appendingPathComponent("MarkerDirectory", isDirectory: true)
        try fileManager.createDirectory(
            at: markerDirectoryRoot.appendingPathComponent(RoomCloudBackupDeletionJournal.markerFilename),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try RoomCloudBackupDeletionJournal(rootURL: markerDirectoryRoot).pendingRequests())

        let mismatchedRoot = temporaryRoot.appendingPathComponent("MarkerMismatch", isDirectory: true)
        try fileManager.createDirectory(at: mismatchedRoot, withIntermediateDirectories: false)
        try RoomCloudBackupDeletionJournal.canonicalData(
            for: RoomCloudBackupDeletionJournal.Marker(schemaVersion: "other-journal-v1", ownershipToken: UUID().uuidString.lowercased())
        ).write(to: mismatchedRoot.appendingPathComponent(RoomCloudBackupDeletionJournal.markerFilename))
        XCTAssertThrowsError(try RoomCloudBackupDeletionJournal(rootURL: mismatchedRoot).replace(makeRequest("ui-project-001")))

        let adopted = temporaryRoot.appendingPathComponent("MarkerlessRoot", isDirectory: true)
        try fileManager.createDirectory(at: adopted, withIntermediateDirectories: false)
        try RoomCloudBackupDeletionJournal(rootURL: adopted).replace(makeRequest("ui-project-001"))
        XCTAssertTrue(fileManager.fileExists(atPath: adopted.appendingPathComponent(RoomCloudBackupDeletionJournal.markerFilename).path))
        attach("VAL-BACKUP-008", "journal-guards",
               "Rejected: empty, slash, dot-dot identifiers; symlinked record (target byte-identical); "
               + "directory record; symlinked ancestor; directory marker; mismatched marker schema. "
               + "Marker-less existing root adopted with a new marker.")
    }

    func testPendingRequestsPersistAcrossInstancesSortedWithoutTransportCalls() throws {
        let root = temporaryRoot.appendingPathComponent("Journal", isDirectory: true)
        let writer = RoomCloudBackupDeletionJournal(rootURL: root)
        let later = makeRequest("project-b", requestedAt: epoch.addingTimeInterval(60))
        let earlierB = makeRequest("project-z", requestedAt: epoch)
        let earlierA = makeRequest("project-a", requestedAt: epoch, knownRecordNames: [recordName("e")])
        for request in [later, earlierB, earlierA] { try writer.replace(request) }
        let spy = SpyCloudBackupTransport()
        let service = makeService(transport: spy, journal: RoomCloudBackupDeletionJournal(rootURL: root))

        let pending = try service.pendingBackupDeletions()

        XCTAssertEqual(pending, [earlierA, earlierB, later])
        XCTAssertEqual(spy.callCount, 0)
        attach("VAL-BACKUP-012", "pending-persist-sorted-no-transport",
               "Fresh journal instance returned \(pending.map(\.projectID)) (requestedAt, projectID); transport calls: \(spy.callCount).")
    }

    // MARK: - Service journal transitions (VAL-BACKUP-010, -011)

    func testPerformRemovesRecordOnlyWhenNothingRemains() async throws {
        let root = temporaryRoot.appendingPathComponent("Journal", isDirectory: true)
        let journal = RoomCloudBackupDeletionJournal(rootURL: root)
        let transport = try seededTransport(descriptors: [descriptor("a"), descriptor("b")])
        let clock = FixedRoomProjectClock(date: epoch.addingTimeInterval(120))
        let service = makeService(transport: transport, journal: journal, clock: clock)
        try service.requestBackupDeletion(projectID: "ui-project-001", displayName: "UI Test Room", containerIdentifier: container)

        transport.partialDeleteFailureCount = 1
        let partial = try await service.performBackupDeletion(projectID: "ui-project-001")
        XCTAssertEqual(partial.remainingRecordNames, [recordName("b")])
        let afterPartial = try XCTUnwrap(try journal.load(projectID: "ui-project-001"))
        XCTAssertEqual(afterPartial.attempts, 1)
        XCTAssertEqual(afterPartial.lastAttemptAt, clock.now())
        XCTAssertNotNil(afterPartial.lastErrorMessage)
        XCTAssertEqual(afterPartial.knownRecordNames, [recordName("b")])

        transport.partialDeleteFailureCount = 0
        transport.deleteErrors = [.networkUnavailable(retryAfterSeconds: nil)]
        do {
            _ = try await service.performBackupDeletion(projectID: "ui-project-001")
            XCTFail("The injected transport error must surface.")
        } catch let error as RoomCloudBackupTransportError {
            XCTAssertTrue(error.isRetryable)
        }
        let afterThrow = try XCTUnwrap(try journal.load(projectID: "ui-project-001"))
        XCTAssertEqual(afterThrow.attempts, 2)
        XCTAssertEqual(afterThrow.lastErrorMessage, "The network is unavailable.")
        XCTAssertEqual(afterThrow.knownRecordNames, [recordName("b")])

        let complete = try await service.performBackupDeletion(projectID: "ui-project-001")
        XCTAssertTrue(complete.isComplete)
        XCTAssertNil(try journal.load(projectID: "ui-project-001"))
        XCTAssertEqual(storedNames(transport), [])
        attach("VAL-BACKUP-010", "journal-transitions",
               "Partial: attempts 1, known \(afterPartial.knownRecordNames), error set. Thrown retryable: attempts 2, "
               + "error '\(afterThrow.lastErrorMessage ?? "")'. Complete: record removed.")
    }

    func testInterruptedCompletionFinishesIdempotentlyOnNextAttempt() async throws {
        let root = temporaryRoot.appendingPathComponent("Journal", isDirectory: true)
        let transport = try seededTransport(descriptors: [descriptor("a"), descriptor("b")])
        let crashing = RoomCloudBackupDeletionJournal(rootURL: root, beforeRemove: {
            throw CocoaError(.fileWriteUnknown)
        })
        let first = makeService(transport: transport, journal: crashing)
        try first.requestBackupDeletion(projectID: "ui-project-001", displayName: "UI Test Room", containerIdentifier: container)
        do {
            _ = try await first.performBackupDeletion(projectID: "ui-project-001")
            XCTFail("The injected journal removal fault must surface.")
        } catch {}
        XCTAssertEqual(storedNames(transport), [], "The remote delete succeeded before the fault.")
        let survivor = try XCTUnwrap(try RoomCloudBackupDeletionJournal(rootURL: root).load(projectID: "ui-project-001"))

        let second = makeService(transport: transport, journal: RoomCloudBackupDeletionJournal(rootURL: root))
        let outcome = try await second.performBackupDeletion(projectID: "ui-project-001")

        XCTAssertEqual(outcome.remainingRecordNames, [])
        XCTAssertNil(try RoomCloudBackupDeletionJournal(rootURL: root).load(projectID: "ui-project-001"))
        attach("VAL-BACKUP-011", "crash-between-delete-and-journal-removal",
               "After fault: remote records 0, journal kept \(survivor.projectID). Next attempt: \(outcome); record removed.")
    }

    // MARK: - Coordinator (VAL-BACKUP-013, -014, -015a, -023)

    func testCoordinatorDeletionStateAndSharedRetryPolicy() async throws {
        let provider = FakeCloudBackupProvider()
        let coordinator = makeCoordinator(provider)
        var states: [RoomCloudBackupCoordinatorState] = []
        let observation = coordinator.$state.sink { states.append($0) }
        await coordinator.deleteBackups(projectID: "project-a", displayName: "Room A")
        observation.cancel()
        XCTAssertEqual(states, [.idle, .deletingBackup, .idle])
        XCTAssertEqual(provider.deleteRequests, ["project-a"])
        XCTAssertEqual(provider.performRequests, ["project-a"])
        XCTAssertEqual(coordinator.pendingDeletions, [])
        XCTAssertNotNil(coordinator.deletionOutcomeMessage)

        let twoRetryable = FakeCloudBackupProvider()
        twoRetryable.deleteErrors = [.rateLimited(retryAfterSeconds: 1), .networkUnavailable(retryAfterSeconds: nil)]
        let twoCoordinator = makeCoordinator(twoRetryable)
        await twoCoordinator.deleteBackups(projectID: "project-b")
        XCTAssertEqual(twoRetryable.performRequests.count, 3)
        XCTAssertEqual(twoCoordinator.state, .idle)

        let exhausted = FakeCloudBackupProvider()
        exhausted.deleteErrors = Array(repeating: .serviceUnavailable(retryAfterSeconds: 0), count: 3)
        let exhaustedCoordinator = makeCoordinator(exhausted)
        await exhaustedCoordinator.deleteBackups(projectID: "project-c")
        XCTAssertEqual(exhaustedCoordinator.state, .failed)
        XCTAssertNotNil(exhaustedCoordinator.errorMessage)
        XCTAssertEqual(exhausted.performRequests.count, 3)
        XCTAssertEqual(exhaustedCoordinator.pendingDeletions.map(\.projectID), ["project-c"])
        XCTAssertEqual(exhaustedCoordinator.pendingDeletions.first?.attempts, 3)

        let fatal = FakeCloudBackupProvider()
        fatal.deleteErrors = [.transportFailure("injected")]
        let fatalCoordinator = makeCoordinator(fatal)
        await fatalCoordinator.deleteBackups(projectID: "project-d")
        XCTAssertEqual(fatalCoordinator.state, .failed)
        XCTAssertEqual(fatal.performRequests.count, 1)

        let service = FakeCloudBackupProvider()
        service.deleteErrors = [.serviceUnavailable(retryAfterSeconds: 0)]
        let serviceCoordinator = makeCoordinator(service)
        await serviceCoordinator.deleteBackups(projectID: "project-e")
        XCTAssertEqual(service.performRequests.count, 2)
        XCTAssertEqual(serviceCoordinator.state, .idle)
        attach("VAL-BACKUP-013", "coordinator-retry-policy",
               "States \(states); [rateLimited, networkUnavailable]+success: 3 performs; 3× serviceUnavailable: "
               + "failed after 3 with request pending; transportFailure: 1 perform; serviceUnavailable+success: 2 performs.")
    }

    func testFailedDeletionCanBeRetriedAndImmediateAttemptIsSingle() async throws {
        let provider = FakeCloudBackupProvider()
        try provider.requestBackupDeletion(projectID: "project-a", displayName: "Room A", containerIdentifier: container)
        provider.deleteErrors = [.networkUnavailable(retryAfterSeconds: nil)]
        let coordinator = makeCoordinator(provider)

        await coordinator.attemptRequestedDeletion(projectID: "project-a")

        XCTAssertEqual(provider.performRequests.count, 1, "The post-purge attempt does not auto-retry.")
        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertEqual(coordinator.pendingDeletions.first?.attempts, 1)
        await coordinator.retryPendingDeletion(projectID: "project-a")
        XCTAssertEqual(provider.performRequests.count, 2)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.pendingDeletions, [])
        XCTAssertNotNil(coordinator.deletionOutcomeMessage)

        await coordinator.attemptRequestedDeletion(projectID: "never-requested")
        XCTAssertEqual(provider.performRequests.count, 2, "No journaled request means no remote call.")
    }

    func testDeleteBackupRecordDeletesExactlyThatRecordAndRefreshesList() async throws {
        let transport = try seededTransport(descriptors: [descriptor("a"), descriptor("b")])
        let service = makeService(
            transport: transport,
            journal: RoomCloudBackupDeletionJournal(rootURL: temporaryRoot.appendingPathComponent("Journal"))
        )
        let coordinator = makeCoordinator(service)
        await coordinator.listBackups()
        let recordA = try XCTUnwrap(coordinator.backups.first { $0.descriptor.snapshotID == descriptor("a").snapshotID })
        XCTAssertEqual(coordinator.backups.count, 2)

        await coordinator.deleteBackupRecord(recordA)

        XCTAssertEqual(transport.deleteInvocations, [.init(projectID: nil, recordNames: [recordName("a")])])
        XCTAssertEqual(storedNames(transport), [recordName("b")])
        let listedAfterRecordDelete = try await listedNames(transport)
        XCTAssertEqual(listedAfterRecordDelete, [recordName("b")])
        XCTAssertEqual(coordinator.backups.map(\.descriptor.recordName), [recordName("b")])
        XCTAssertEqual(coordinator.state, .idle)
        let message = try XCTUnwrap(coordinator.deletionOutcomeMessage)
        XCTAssertTrue(message.contains("Apple"))
        XCTAssertTrue(message.contains("cannot verify physical erasure"))
        XCTAssertEqual(try service.pendingBackupDeletions(), [], "Per-record deletion is not journaled.")
        attach("VAL-BACKUP-014", "delete-exact-record",
               "Invocations \(transport.deleteInvocations); remaining store \(storedNames(transport)); "
               + "coordinator.backups \(coordinator.backups.map(\.descriptor.recordName)); outcome '\(message)'.")
    }

    func testPendingStateIsReadWithoutAnyTransportOrProviderCall() async throws {
        let provider = FakeCloudBackupProvider()
        try provider.requestBackupDeletion(projectID: "project-a", displayName: "Room A", containerIdentifier: container)
        let deleteRequestsBefore = provider.deleteRequests

        let coordinator = makeCoordinator(provider)

        XCTAssertEqual(coordinator.pendingDeletions.map(\.projectID), ["project-a"])
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertTrue(provider.performRequests.isEmpty)
        XCTAssertEqual(provider.deleteRequests, deleteRequestsBefore)
        XCTAssertNil(coordinator.deletionOutcomeMessage)
        XCTAssertNil(coordinator.accountStatus)

        let root = temporaryRoot.appendingPathComponent("Journal", isDirectory: true)
        try RoomCloudBackupDeletionJournal(rootURL: root).replace(makeRequest("project-b"))
        let spy = SpyCloudBackupTransport()
        let spyCoordinator = makeCoordinator(makeService(transport: spy, journal: RoomCloudBackupDeletionJournal(rootURL: root)))
        XCTAssertEqual(spyCoordinator.pendingDeletions.map(\.projectID), ["project-b"])
        XCTAssertEqual(spy.callCount, 0)
        attach("VAL-BACKUP-015", "pending-read-zero-calls",
               "Coordinator construction + pendingDeletions: provider calls \(provider.callCount), performs 0; "
               + "real service over journal: transport calls \(spy.callCount).")
    }

    func testPendingLabelCarriesNameDateAttemptsErrorAndStillInICloud() {
        var request = makeRequest("ui-project-001")
        request.displayName = "UI Test Room"
        request.attempts = 2
        request.lastErrorMessage = "Injected network unavailable."
        let label = RoomCloudBackupSettingsView.pendingLabel(request)
        for expected in [
            "UI Test Room", RoomCloudBackupSettingsView.requestDate(request.requestedAt), "Attempts: 2",
            "Injected network unavailable.", "still in iCloud",
        ] {
            XCTAssertTrue(label.contains(expected), "\(expected) missing from \(label)")
        }
        attach("VAL-BACKUP-023", "pending-label", label)
    }

    func testPurgeRequesterJournalsOnlyWhenEnabledAndConfigured() async throws {
        for (enabled, identifier, expected) in [
            (true, container, ["project-a"]),
            (false, container, []),
            (true, "$(CLOUD_CONTAINER)", []),
            (true, "", []),
        ] as [(Bool, String, [String])] {
            let provider = FakeCloudBackupProvider()
            let requester = RoomCloudBackupPurgeDeletionRequester(
                preferences: RoomCloudBackupPreferences(isEnabled: enabled, containerIdentifier: identifier, defaults: nil),
                provider: provider
            )
            try await requester.requestDeletion(projectID: "project-a")
            XCTAssertEqual(provider.deleteRequests, expected, "enabled=\(enabled) container=\(identifier)")
            XCTAssertEqual(provider.callCount, 0)
        }
        let unbound = RoomCloudBackupPurgeDeletionRequester(
            preferences: RoomCloudBackupPreferences(isEnabled: true, containerIdentifier: container, defaults: nil)
        )
        do {
            try await unbound.requestDeletion(projectID: "project-a")
            XCTFail("An enabled requester without a journal must fail closed.")
        } catch {
            XCTAssertEqual(error as? RoomCloudBackupDeletionServiceError, .journalUnavailable)
        }
    }

    // MARK: - Purge and reaper (VAL-BACKUP-009, -015b)

    func testPurgeJournalsBeforePackageRemovalFailsClosedAndSkipsWhenDisabled() async throws {
        let store = makeProjectStore(projectIDs: ["ordered", "fail-closed", "disabled", "unconfigured", "keep"])
        for _ in 0..<5 { _ = try await saveTrashedProject(in: store) }

        // Order: the requester runs while the package is still on disk.
        let provider = FakeCloudBackupProvider()
        let events = PurgeEventRecorder()
        let ordered = makePurgeCoordinator(store: store, requester: makeRequester(provider), events: events)
        let orderedReport = await ordered.purge(projectID: "ordered", mode: .manual, backup: .requestDeletion)
        events.events.append(packageExists("ordered") ? "package present after purge" : "package removed")
        XCTAssertEqual(orderedReport.package, .removed)
        XCTAssertEqual(events.events, ["journal ordered (package present)", "package removed"])
        XCTAssertEqual(provider.deleteRequests, ["ordered"])
        XCTAssertEqual(provider.callCount, 0, "Purge journals locally; it never performs a remote delete.")

        // Fail-closed: a journal failure stops the purge and keeps the package.
        let failing = FakeCloudBackupProvider()
        failing.requestErrors = [CocoaError(.fileWriteNoPermission)]
        let failClosed = await makePurgeCoordinator(
            store: store, requester: makeRequester(failing), events: PurgeEventRecorder()
        ).purge(projectID: "fail-closed", mode: .manual, backup: .requestDeletion)
        XCTAssertTrue(failClosed.package.failed, "\(failClosed)")
        XCTAssertFalse(failClosed.packageDeleted)
        XCTAssertTrue(failClosed.companions.isEmpty)
        XCTAssertTrue(packageExists("fail-closed"))
        XCTAssertEqual(failing.deleteRequests, [])

        // Disabled and unconfigured backup: nothing journaled, package deleted.
        let disabledProvider = FakeCloudBackupProvider()
        let disabled = await makePurgeCoordinator(
            store: store, requester: makeRequester(disabledProvider, enabled: false), events: PurgeEventRecorder()
        ).purge(projectID: "disabled", mode: .manual, backup: .requestDeletion)
        let unconfiguredProvider = FakeCloudBackupProvider()
        let unconfigured = await makePurgeCoordinator(
            store: store, requester: makeRequester(unconfiguredProvider, container: "$(CLOUD_CONTAINER)"),
            events: PurgeEventRecorder()
        ).purge(projectID: "unconfigured", mode: .manual, backup: .requestDeletion)
        XCTAssertEqual(disabled.package, .removed)
        XCTAssertEqual(unconfigured.package, .removed)
        XCTAssertEqual(disabledProvider.deleteRequests, [])
        XCTAssertEqual(unconfiguredProvider.deleteRequests, [])
        XCTAssertFalse(packageExists("disabled"))
        XCTAssertFalse(packageExists("unconfigured"))

        // Keep: the hook is never invoked, even while enabled and configured.
        let keepEvents = PurgeEventRecorder()
        let keepProvider = FakeCloudBackupProvider()
        let kept = await makePurgeCoordinator(store: store, requester: makeRequester(keepProvider), events: keepEvents)
            .purge(projectID: "keep", mode: .manual, backup: .keep)
        XCTAssertEqual(kept.package, .removed)
        XCTAssertEqual(keepEvents.events, [])
        XCTAssertEqual(keepProvider.deleteRequests, [])
        attach("VAL-BACKUP-009", "journal-before-delete-fail-closed-disabled",
               "Order: \(events.events). Fail-closed report: \(failClosed), package kept. "
               + "Disabled: \(disabled.package), unconfigured: \(unconfigured.package), zero requests. "
               + "Keep: \(kept.package), hook not invoked.")
    }

    func testReaperOnlyJournalsAndNeverCallsTheTransport() async throws {
        let store = makeProjectStore(projectIDs: ["expired-project"])
        let saved = try await saveTrashedProject(in: store, trashedAt: epoch.addingTimeInterval(-31 * 24 * 60 * 60))
        let provider = FakeCloudBackupProvider()
        let reaper = RoomTrashReaper(
            store: store,
            purgeCoordinator: RoomProjectPurgeCoordinator(
                store: store,
                clock: FixedRoomProjectClock(date: epoch),
                deletionRequest: { try await self.makeRequester(provider).requestDeletion(projectID: $0) }
            ),
            clock: FixedRoomProjectClock(date: epoch)
        )

        let report = await reaper.purgeExpiredTrash()

        XCTAssertEqual(report.purgedCount, 1)
        XCTAssertEqual(provider.deleteRequests, [saved.projectID])
        XCTAssertTrue(provider.performRequests.isEmpty)
        XCTAssertEqual(provider.callCount, 0)

        // The same path through the real service and journal reaches no transport method.
        let secondStore = makeProjectStore(projectIDs: ["expired-real"], rootName: "ProjectsReal")
        let second = try await saveTrashedProject(
            in: secondStore, trashedAt: epoch.addingTimeInterval(-31 * 24 * 60 * 60), rootName: "ProjectsReal"
        )
        let spy = SpyCloudBackupTransport()
        let journalRoot = temporaryRoot.appendingPathComponent("ReaperJournal", isDirectory: true)
        let service = makeService(transport: spy, journal: RoomCloudBackupDeletionJournal(rootURL: journalRoot))
        let realRequester = makeRequester(service)
        let realReport = await RoomTrashReaper(
            store: secondStore,
            purgeCoordinator: RoomProjectPurgeCoordinator(
                store: secondStore,
                clock: FixedRoomProjectClock(date: epoch),
                deletionRequest: { try await realRequester.requestDeletion(projectID: $0) }
            ),
            clock: FixedRoomProjectClock(date: epoch)
        ).purgeExpiredTrash()

        XCTAssertEqual(realReport.purgedCount, 1)
        XCTAssertEqual(spy.deleteBackupsCalls, 0)
        XCTAssertEqual(spy.callCount, 0)
        let journaled = try XCTUnwrap(try RoomCloudBackupDeletionJournal(rootURL: journalRoot).load(projectID: second.projectID))
        XCTAssertEqual(journaled.attempts, 0)
        XCTAssertEqual(journaled.containerIdentifier, container)
        attach("VAL-BACKUP-015", "reaper-journal-only",
               "Fake provider: deleteRequests \(provider.deleteRequests), performs \(provider.performRequests.count). "
               + "Real service + spy transport: deleteBackups calls \(spy.deleteBackupsCalls), total calls \(spy.callCount); "
               + "journal record \(journaled.projectID) attempts \(journaled.attempts).")
    }

    // MARK: - Helpers

    private func makeProjectStore(projectIDs: [String], rootName: String = "Projects") -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: temporaryRoot.appendingPathComponent(rootName, isDirectory: true),
            clock: FixedRoomProjectClock(date: epoch),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: projectIDs,
                revisionIDs: projectIDs.indices.map { "revision-\($0 + 1)" }
            )
        )
    }

    private func saveTrashedProject(
        in store: LocalRoomProjectStore,
        trashedAt: Date? = nil,
        rootName: String = "Projects"
    ) async throws -> RoomProjectSummary {
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let result = try await store.saveDraft(fixture.draft, decision: .save, assets: fixture.assets)
        let saved = try XCTUnwrap(result)
        try await LocalRoomProjectStore(
            rootURL: temporaryRoot.appendingPathComponent(rootName, isDirectory: true),
            clock: FixedRoomProjectClock(date: trashedAt ?? epoch)
        ).moveToTrash(projectID: saved.projectID)
        return saved
    }

    private func packageExists(_ projectID: String) -> Bool {
        fileManager.fileExists(atPath: temporaryRoot.appendingPathComponent("Projects/\(projectID)").path)
    }

    private func makeRequester(
        _ provider: any RoomCloudBackupProviding,
        enabled: Bool = true,
        container identifier: String? = nil
    ) -> RoomCloudBackupPurgeDeletionRequester {
        RoomCloudBackupPurgeDeletionRequester(
            preferences: RoomCloudBackupPreferences(
                isEnabled: enabled, containerIdentifier: identifier ?? container, defaults: nil
            ),
            provider: provider
        )
    }

    private func makePurgeCoordinator(
        store: LocalRoomProjectStore,
        requester: RoomCloudBackupPurgeDeletionRequester,
        events: PurgeEventRecorder
    ) -> RoomProjectPurgeCoordinator {
        RoomProjectPurgeCoordinator(store: store, deletionRequest: { projectID in
            events.events.append("journal \(projectID) (package \(self.packageExists(projectID) ? "present" : "absent"))")
            try await requester.requestDeletion(projectID: projectID)
        })
    }

    private func recordName(_ character: Character) -> String {
        "rssb1-" + String(repeating: String(character), count: 64)
    }

    private func descriptor(_ character: Character, projectID: String = "ui-project-001") -> RoomCloudBackupDescriptor {
        let hash = String(repeating: String(character), count: 64)
        return RoomCloudBackupDescriptor(
            snapshotID: hash,
            projectID: projectID,
            headRevisionID: "revision-001",
            projectSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            displayName: "UI Test Room",
            sourceUpdatedAt: epoch,
            revisionCount: 1,
            fileCount: 7,
            uncompressedByteCount: 256,
            manifestSHA256: hash,
            archiveSHA256: String(repeating: "d", count: 64),
            archiveByteCount: 512
        )
    }

    private struct SeededState: Encodable {
        let zoneExists: Bool
        let descriptors: [RoomCloudBackupDescriptor]
    }

    /// Seeds through the fake's own persistence format, then reloads it.
    private func seededTransport(
        descriptors: [RoomCloudBackupDescriptor],
        root: URL? = nil
    ) throws -> DeterministicCloudBackupTransport {
        let seedRoot = root ?? temporaryRoot.appendingPathComponent("Seed-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: seedRoot, withIntermediateDirectories: true)
        try RoomCloudBackupDeletionJournal.canonicalData(for: SeededState(zoneExists: true, descriptors: descriptors))
            .write(to: seedRoot.appendingPathComponent("records.json"))
        let transport = DeterministicCloudBackupTransport(persistenceRootURL: seedRoot)
        XCTAssertEqual(transport.storedRecordNames, descriptors.map(\.recordName).sorted())
        return transport
    }

    private func storedNames(_ transport: DeterministicCloudBackupTransport) -> [String] {
        transport.storedRecordNames
    }

    private func listedNames(_ transport: DeterministicCloudBackupTransport) async throws -> [String] {
        switch try await transport.listBackups(containerIdentifier: container) {
        case .zoneMissing: return []
        case let .backups(listing): return listing.records.map(\.descriptor.recordName).sorted()
        }
    }

    private func makeRequest(
        _ projectID: String,
        requestedAt: Date? = nil,
        knownRecordNames: [String] = []
    ) -> RoomCloudBackupDeletionRequest {
        RoomCloudBackupDeletionRequest(
            projectID: projectID,
            containerIdentifier: container,
            displayName: "Synthetic \(projectID)",
            requestedAt: requestedAt ?? epoch,
            knownRecordNames: knownRecordNames
        )
    }

    private func makeService(
        transport: any RoomCloudBackupTransport,
        journal: RoomCloudBackupDeletionJournal,
        clock: any RoomProjectClock = FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_800_014_400))
    ) -> RoomCloudBackupService {
        let store = LocalRoomProjectStore(rootURL: temporaryRoot.appendingPathComponent("Projects", isDirectory: true))
        return RoomCloudBackupService(
            controller: RoomLibraryController(store: store, modelContainer: nil),
            workspaceFactory: RoomCloudBackupWorkspaceFactory(
                rootURL: temporaryRoot.appendingPathComponent("CloudBackupScratch", isDirectory: true)
            ),
            transport: transport,
            deletionJournal: journal,
            clock: clock
        )
    }

    private func makeCoordinator(_ provider: any RoomCloudBackupProviding) -> RoomCloudBackupCoordinator {
        RoomCloudBackupCoordinator(
            provider: provider,
            preferences: RoomCloudBackupPreferences(isEnabled: true, containerIdentifier: container, defaults: nil),
            sleeper: ImmediateCloudBackupSleeper()
        )
    }

    private func attach(_ contractID: String, _ slug: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(contractID)-\(slug)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class PurgeEventRecorder {
    var events: [String] = []
}

/// Counts every transport entry point so tests can prove zero remote calls.
@MainActor
final class SpyCloudBackupTransport: RoomCloudBackupTransport {
    private(set) var callCount = 0
    private(set) var deleteBackupsCalls = 0

    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus {
        callCount += 1
        return .available
    }

    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult {
        callCount += 1
        return .zoneMissing
    }

    func ensureBackupZone(containerIdentifier: String) async throws {
        callCount += 1
    }

    func save(snapshot: RoomBackupSnapshot, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord {
        callCount += 1
        throw RoomCloudBackupTransportError.transportFailure("spy")
    }

    func lookup(snapshotID: String, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord? {
        callCount += 1
        return nil
    }

    func fetchArchive(record: RoomCloudBackupRemoteRecord, containerIdentifier: String, into destinationURL: URL) async throws {
        callCount += 1
        throw RoomCloudBackupTransportError.transportFailure("spy")
    }

    func deleteBackups(
        projectID: String,
        knownRecordNames: [String],
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome {
        callCount += 1
        deleteBackupsCalls += 1
        return RoomCloudBackupDeletionOutcome(deletedRecordNames: knownRecordNames)
    }

    func deleteBackupRecords(
        named recordNames: [String],
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome {
        callCount += 1
        deleteBackupsCalls += 1
        return RoomCloudBackupDeletionOutcome(deletedRecordNames: recordNames)
    }
}
