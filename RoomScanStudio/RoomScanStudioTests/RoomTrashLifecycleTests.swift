import Foundation
import RoomScanCore
import SwiftData
import SwiftUI
import XCTest
@testable import RoomScanStudio

/// Simulator app-layer proofs only: every package, companion, and canary is
/// synthetic, and every filesystem write is beneath this test's owned root.
@MainActor
final class RoomTrashLifecycleTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryRoot: URL!
    private let epoch = Date(timeIntervalSince1970: 1_800_014_400)
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("RoomTrashLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        // Remove only the directory this test allocated, never app/UI roots.
        if let temporaryRoot {
            try fileManager.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    func testUITestAppearanceRequiresBothIsolationFlagsAndAValidStyle() {
        let style = ["-AppleInterfaceStyle", "Dark"]
        for flags in [[], ["--ui-testing"], ["--reset-local-store"]] {
            XCTAssertNil(IsolatedUITestAppearance.resolve(arguments: flags + style))
        }
        let isolated = ["--ui-testing", "--reset-local-store"]
        XCTAssertEqual(IsolatedUITestAppearance.resolve(arguments: isolated + style), .dark)
        XCTAssertEqual(IsolatedUITestAppearance.resolve(
            arguments: isolated + ["-AppleInterfaceStyle", "Light"]
        ), .light)
        XCTAssertNil(IsolatedUITestAppearance.resolve(arguments: isolated))
        XCTAssertNil(IsolatedUITestAppearance.resolve(arguments: isolated + ["-AppleInterfaceStyle"]))
        XCTAssertNil(IsolatedUITestAppearance.resolve(
            arguments: isolated + ["-AppleInterfaceStyle", "unsupported"]
        ))
        attach("VAL-TRASH-030", "isolated-appearance-argument-boundary",
               "Dark and Light overrides require both isolated-run flags and a recognized style; "
               + "normal, partial, missing and malformed arguments leave system appearance unchanged.")
    }

    func testPurgeRemovesEveryRealCompanionAndIndexButPreservesPublishedOperationAuditBytes() async throws {
        let store = makeStore(projectIDs: ["project-001"])
        let saved = try await saveProject(in: store)
        let source = try await store.redesignSourceRevisionBinding(
            projectID: saved.projectID, revisionID: saved.headRevisionID
        )
        let redesign = LocalRoomRedesignStore(rootURL: root("RedesignState"))
        try await seedRedesign(in: redesign, store: store, source: source)
        let concepts = makeConceptStore()
        let imported = try await concepts.importConceptSet(
            conceptImport(source: source),
            context: .init(expectedSourceRevision: source, currentCanonicalCameraIDs: [])
        )
        XCTAssertEqual(imported.conceptSetID, "concept-001")
        let conceptDirectory = conceptDirectory(source: source, conceptID: imported.conceptSetID)
        XCTAssertTrue(fileManager.fileExists(
            atPath: conceptDirectory.appendingPathComponent(Self.ownershipFilename).path
        ), "Positive control: the real import must establish ownership.")
        let properties = LocalRoomPropertyStore(rootURL: root("Properties"))
        let firstProperty = property("property-001", members: ["project-other-a", saved.projectID, "project-other-b"])
        let secondProperty = property("property-002", members: [saved.projectID, "project-other-c"])
        // Normal save forbids duplicate membership. Seed canonical files,
        // like Core's detach regression, to prove cleanup handles every
        // pre-existing on-disk membership rather than only the first match.
        try fileManager.createDirectory(at: root("Properties"), withIntermediateDirectories: false)
        for property in [firstProperty, secondProperty] {
            try RoomRedesignCanonicalJSON.encode(property)
                .write(to: root("Properties").appendingPathComponent("\(property.propertyID).json"))
        }
        let syncJournal = try ProfessionalProjectSyncJournal(rootURL: root("ProfessionalSyncJournal"))
        try syncJournal.replace(syncRecord(for: saved))
        XCTAssertNotNil(try syncJournal.load(localProjectID: saved.projectID))
        let audit = try await seedPublishedOperation(source: source)
        let auditBefore = try Data(contentsOf: audit.url)
        XCTAssertEqual(try audit.journal.load(operationID: audit.record.operationID)?.phase, .published)
        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        try await rebuildIndex(store: store, container: container)
        XCTAssertEqual(try indexRecords(container).map(\.projectID), [saved.projectID])
        let coordinator = RoomProjectPurgeCoordinator(
            store: store,
            redesignStore: redesign,
            conceptStore: concepts,
            propertyStore: properties,
            syncJournal: syncJournal,
            modelContainer: container
        )

        let report = await coordinator.purge(projectID: saved.projectID)

        XCTAssertEqual(report.projectID, saved.projectID)
        XCTAssertEqual(report.package, .removed)
        XCTAssertTrue(report.packageDeleted)
        XCTAssertFalse(report.hasFailures)
        XCTAssertEqual(report.companions.count, 5)
        XCTAssertEqual(report.companions.filter { $0.companion == .redesignState }.map(\.result), [.removed])
        XCTAssertEqual(report.companions.filter { $0.companion == .conceptSets }.map(\.result), [.removed])
        XCTAssertEqual(report.companions.filter { $0.companion == .propertyMembership }.map(\.result), [.removed])
        XCTAssertEqual(report.companions.filter { $0.companion == .professionalSyncJournal }.map(\.result), [.removed])
        XCTAssertEqual(report.companions.filter { $0.companion == .index }.map(\.result), [.removed])
        for directory in [projectURL(saved.projectID), root("RedesignState").appendingPathComponent(saved.projectID),
                          root("ConceptSets").appendingPathComponent(saved.projectID)] {
            XCTAssertFalse(fileManager.fileExists(atPath: directory.path))
        }
        XCTAssertFalse(fileManager.fileExists(atPath: root("ProfessionalSyncJournal")
            .appendingPathComponent("records/\(saved.projectID).json").path))
        XCTAssertNil(try syncJournal.load(localProjectID: saved.projectID))
        for original in [firstProperty, secondProperty] {
            var expected = original
            expected.roomProjectIDs.removeAll { $0 == saved.projectID }
            let bytes = try Data(contentsOf: root("Properties").appendingPathComponent("\(original.propertyID).json"))
            XCTAssertEqual(bytes, try RoomRedesignCanonicalJSON.encode(expected),
                           "Detach must keep the property, other members, and all other fields.")
        }
        XCTAssertEqual(try indexRecords(container).count, 0)
        XCTAssertEqual(try Data(contentsOf: audit.url), auditBefore)
        XCTAssertEqual(try audit.journal.load(operationID: audit.record.operationID), audit.record)
        attach("VAL-TRASH-008", "real-companions-and-published-audit",
               "Package, redesign, imported Concept Set, both property memberships, sync record and index removed. "
               + "Property files retained with exact remaining fields. Real .published operation bytes unchanged; "
               + "SHA256=\(RoomSHA256.hexDigest(of: auditBefore)).")
    }

    func testMixedConceptOwnershipReportsFailureRemovesSafeChildAndNeverResurrectsPackage() async throws {
        let store = makeStore(projectIDs: ["project-001"])
        let saved = try await saveProject(in: store)
        let source = try await store.redesignSourceRevisionBinding(
            projectID: saved.projectID, revisionID: saved.headRevisionID
        )
        try await store.moveToTrash(projectID: saved.projectID)
        let concepts = makeConceptStore()
        _ = try await concepts.importConceptSet(
            conceptImport(source: source, conceptID: "z-valid"),
            context: .init(expectedSourceRevision: source, currentCanonicalCameraIDs: [])
        )
        let valid = conceptDirectory(source: source, conceptID: "z-valid")
        let unmarked = conceptDirectory(source: source, conceptID: "a-unmarked")
        try writeCanary(at: unmarked.appendingPathComponent("keep"))
        let mismatched = conceptDirectory(source: source, conceptID: "b-mismatched")
        try writeCanary(at: mismatched.appendingPathComponent("keep"))
        var otherSource = source
        otherSource.projectID = "project-other"
        let wrongMarker = try RoomConceptSetCanonicalJSON.encode(
            ConceptOwnership(sourceRevision: otherSource, conceptSetID: "b-mismatched")
        )
        try wrongMarker.write(to: mismatched.appendingPathComponent(Self.ownershipFilename))
        let external = root("ExternalConceptCanary")
        try writeCanary(at: external.appendingPathComponent("keep"))
        let linked = conceptDirectory(source: source, conceptID: "c-linked")
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: external)
        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        try await rebuildIndex(store: store, container: container)
        let coordinator = RoomProjectPurgeCoordinator(store: store, conceptStore: concepts, modelContainer: container)

        let report = await coordinator.purge(projectID: saved.projectID)

        XCTAssertEqual(report.package, .removed)
        XCTAssertTrue(report.packageDeleted)
        XCTAssertTrue(report.hasFailures)
        let result = try XCTUnwrap(report.companions.first { $0.companion == .conceptSets }?.result)
        guard case .failed(let message) = result else {
            return XCTFail("Unsafe concept children must produce a companion failure, got \(result).")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: valid.path), "Attempt safe children even after earlier failures.")
        XCTAssertEqual(try Data(contentsOf: unmarked.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try Data(contentsOf: mismatched.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try Data(contentsOf: mismatched.appendingPathComponent(Self.ownershipFilename)), wrongMarker)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linked.path), external.path)
        XCTAssertFalse(fileManager.fileExists(atPath: projectURL(saved.projectID).path))
        let listing = try await store.listProjectListing(includeArchived: true, includeTrashed: true)
        XCTAssertFalse(listing.summaries.contains { $0.projectID == saved.projectID })
        XCTAssertEqual(try indexRecords(container).count, 0, "Concept failure cannot prevent removal of the stale index row.")
        XCTAssertEqual(report.companions.filter { $0.companion == .index }.map(\.result), [.removed])
        attach("VAL-TRASH-009", "mixed-ownership-failure-and-index",
               "Valid imported child removed; unmarked/mismatched children and external symlink target byte-identical. "
               + "Concept failure reported; package absent from disk/listing and index row removed.")
    }

    func testPurgeIsIdempotentAndAbsentCompanionRemovalCreatesNoDirectories() async throws {
        let store = makeStore(projectIDs: ["project-001"])
        let saved = try await saveProject(in: store)
        let redesign = LocalRoomRedesignStore(rootURL: root("RedesignState"))
        let concepts = makeConceptStore()
        let properties = LocalRoomPropertyStore(rootURL: root("Properties"))
        for _ in 0..<2 {
            let removedRedesign = try await redesign.removeAll(projectID: "missing-project")
            let removedConcepts = try await concepts.removeAll(projectID: "missing-project")
            XCTAssertFalse(removedRedesign)
            XCTAssertFalse(removedConcepts)
        }
        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        let coordinator = RoomProjectPurgeCoordinator(
            store: store,
            redesignStore: redesign,
            conceptStore: concepts,
            propertyStore: properties,
            syncJournalRootURL: root("ProfessionalSyncJournal"),
            modelContainer: container
        )

        let first = await coordinator.purge(projectID: saved.projectID)
        let pathsBeforeRepeat = try relativePaths()
        let second = await coordinator.purge(projectID: saved.projectID)

        XCTAssertEqual(first.package, .removed)
        XCTAssertEqual(second.package, .alreadyAbsent)
        for report in [first, second] {
            XCTAssertFalse(report.hasFailures)
            XCTAssertEqual(report.companions.count, 5)
            XCTAssertEqual(report.companions.filter { $0.companion == .redesignState }.map(\.result), [.alreadyAbsent])
            XCTAssertEqual(report.companions.filter { $0.companion == .conceptSets }.map(\.result), [.alreadyAbsent])
            XCTAssertEqual(report.companions.filter { $0.companion == .propertyMembership }.map(\.result), [.alreadyAbsent])
            XCTAssertEqual(report.companions.filter { $0.companion == .professionalSyncJournal }.map(\.result), [.alreadyAbsent])
            XCTAssertEqual(report.companions.filter { $0.companion == .index }.map(\.result), [.alreadyAbsent])
        }
        for name in ["RedesignState", "ConceptSets", "Properties", "ProfessionalSyncJournal"] {
            XCTAssertFalse(fileManager.fileExists(atPath: root(name).path), "Cleanup must not initialize absent \(name).")
        }
        XCTAssertEqual(try relativePaths(), pathsBeforeRepeat)
        attach("VAL-TRASH-010", "idempotent-purge-no-new-roots",
               "Direct removeAll twice returned false without creating roots. First purge removed package; "
               + "second reported alreadyAbsent. Five companion results alreadyAbsent; no companion directories created.")
    }

    func testDeletionRequestIsAwaitedWhilePackageStillExistsBeforePurge() async throws {
        let store = makeStore(projectIDs: ["project-001"])
        let saved = try await saveProject(in: store)
        let gate = TrashLifecycleGate()
        let requestURL = root("DeletionRequests").appendingPathComponent("\(saved.projectID).json")
        var events: [String] = []
        let coordinator = RoomProjectPurgeCoordinator(store: store, deletionRequest: { projectID in
            XCTAssertEqual(projectID, saved.projectID)
            let package = try await store.load(projectID: projectID)
            XCTAssertEqual(package.manifest.headRevisionID, saved.headRevisionID)
            events.append("request-entered-with-package")
            await gate.suspend()
            try self.writeCanary(at: requestURL)
            events.append("request-durable")
        })
        let task = Task { await coordinator.purge(projectID: saved.projectID) }
        defer { gate.release() }
        await fulfillment(of: [gate.enteredExpectation], timeout: 10)
        guard gate.hasEntered else {
            task.cancel()
            return
        }
        XCTAssertTrue(fileManager.fileExists(atPath: projectURL(saved.projectID).path))
        XCTAssertEqual(events, ["request-entered-with-package"])
        XCTAssertFalse(fileManager.fileExists(atPath: requestURL.path))

        gate.release()
        let report = await task.value
        events.append("purge-returned")

        XCTAssertEqual(events, ["request-entered-with-package", "request-durable", "purge-returned"])
        XCTAssertEqual(try Data(contentsOf: requestURL), Self.canary)
        XCTAssertEqual(report.package, .removed)
        XCTAssertFalse(report.hasFailures)
        XCTAssertFalse(fileManager.fileExists(atPath: projectURL(saved.projectID).path))
        attach("VAL-TRASH-008", "deletion-hook-before-package",
               "Injected request suspended with package readable; package stayed present until durable hook returned. "
               + "Observed order: \(events.joined(separator: ", ")). Journal-only seam, not CloudKit evidence.")
    }

    func testDeletionRequestFailureFailsClosedAndLeavesPackageCompanionsAndIndexUnchanged() async throws {
        let store = makeStore(projectIDs: ["project-001"])
        let saved = try await saveProject(in: store)
        try await store.moveToTrash(projectID: saved.projectID)
        let redesignURL = root("RedesignState").appendingPathComponent("\(saved.projectID)/keep")
        try writeCanary(at: redesignURL)
        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        try await rebuildIndex(store: store, container: container)
        let packageBefore = try bytesUnder(projectURL(saved.projectID))
        var requestIDs: [String] = []
        let coordinator = RoomProjectPurgeCoordinator(
            store: store,
            redesignStore: LocalRoomRedesignStore(rootURL: root("RedesignState")),
            modelContainer: container,
            deletionRequest: { projectID in
                requestIDs.append(projectID)
                throw TrashLifecycleFailure.deletionRequest
            }
        )

        let report = await coordinator.purge(projectID: saved.projectID)

        XCTAssertEqual(requestIDs, [saved.projectID])
        XCTAssertTrue(report.hasFailures)
        XCTAssertFalse(report.packageDeleted)
        guard case .failed(let message) = report.package else {
            return XCTFail("A journal-hook failure must be returned as a failed package purge.")
        }
        XCTAssertTrue(message.contains("Synthetic deletion request failed"), "Surface the injected request failure.")
        XCTAssertEqual(try bytesUnder(projectURL(saved.projectID)), packageBefore)
        XCTAssertEqual(try Data(contentsOf: redesignURL), Self.canary)
        XCTAssertEqual(try indexRecords(container).map(\.projectID), [saved.projectID])
        let listing = try await store.listProjectListing(includeArchived: true, includeTrashed: true)
        XCTAssertEqual(listing.summaries.map(\.projectID), [saved.projectID])
        attach("VAL-TRASH-008", "deletion-hook-fail-closed",
               "Throwing pre-delete hook invoked once; failure reported. Package tree byte-identical, "
               + "redesign canary unchanged, trash listing and index row retained.")
    }

    func testPackageDeletionFailureReturnsReportWithoutFollowingPackageSymlink() async throws {
        let store = makeStore(projectIDs: [])
        let external = root("ExternalPackage")
        try writeCanary(at: external.appendingPathComponent("keep"))
        try fileManager.createDirectory(at: root("Projects"), withIntermediateDirectories: false)
        let link = projectURL("project-linked")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: external)

        let report = await RoomProjectPurgeCoordinator(store: store).purge(projectID: "project-linked")

        XCTAssertEqual(report.projectID, "project-linked")
        XCTAssertTrue(report.hasFailures)
        XCTAssertFalse(report.packageDeleted)
        guard case .failed(let message) = report.package else {
            return XCTFail("A symlinked package must produce a failure report.")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("keep")), Self.canary)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.path), external.path)
        attach("VAL-TRASH-009", "package-symlink-error-report",
               "Symlinked package deletion returned failed, did not throw or follow the link; external canary unchanged.")
    }

    func testReaperPurgesOnlyExpiredTrashInProjectIDOrderIncludingArchivedExactBoundary() async throws {
        let store = makeStore(projectIDs: ["P4", "P2", "P3", "P1"])
        for id in ["P4", "P2", "P3", "P1"] {
            let saved = try await saveProject(in: store, archived: id == "P4")
            XCTAssertEqual(saved.projectID, id)
        }
        try await trash("P1", at: epoch.addingTimeInterval(-31 * day))
        try await trash("P2", at: epoch.addingTimeInterval(-day))
        try await trash("P4", at: epoch.addingTimeInterval(-30 * day))
        let spy = TrashRecordingPurger(real: RoomProjectPurgeCoordinator(store: store))
        let reaper = RoomTrashReaper(store: store, purgeCoordinator: spy, clock: FixedRoomProjectClock(date: epoch))

        let report = await reaper.purgeExpiredTrash()

        XCTAssertNil(report.listingErrorMessage)
        XCTAssertEqual(spy.projectIDs, ["P1", "P4"])
        XCTAssertEqual(report.purgeReports.map(\.projectID), ["P1", "P4"])
        XCTAssertEqual(report.purgedCount, 2)
        XCTAssertTrue(report.purgeReports.allSatisfy { $0.package == .removed && !$0.hasFailures })
        let listing = try await store.listProjectListing(includeArchived: true, includeTrashed: true)
        XCTAssertEqual(Set(listing.summaries.map(\.projectID)), Set(["P2", "P3"]))
        XCTAssertEqual(listing.summaries.first { $0.projectID == "P2" }?.trashedAt, epoch.addingTimeInterval(-day))
        XCTAssertEqual(listing.summaries.first { $0.projectID == "P3" }?.isTrashed, false)
        attach("VAL-TRASH-011", "exact-expiry-set-and-order",
               "Real package purge delegated through spy exactly once in order P1,P4. "
               + "P4 archived and exactly 30 days old; P2 recent trash and P3 active retained; purgedCount=2.")
    }

    func testRealReaperWithComposedFakeCloudServiceMakesZeroTransportCalls() async throws {
        let store = makeStore(projectIDs: ["expired-project"])
        let saved = try await saveProject(in: store)
        try await trash(saved.projectID, at: epoch.addingTimeInterval(-31 * day))
        let controller = RoomLibraryController(store: store, modelContainer: nil)
        let transport = TrashCloudTransportSpy()
        let service = RoomCloudBackupService(
            controller: controller,
            workspaceFactory: RoomCloudBackupWorkspaceFactory(rootURL: root("CloudScratch")),
            transport: transport
        )
        let backup = RoomCloudBackupCoordinator(
            provider: service,
            preferences: RoomCloudBackupPreferences(
                isEnabled: true,
                containerIdentifier: CloudBackupContainerArgument.deterministicFakeContainerIdentifier,
                defaults: nil
            )
        )
        // Positive control: the service genuinely reaches this spy. This is
        // an in-memory fake method, not a production account/provider call.
        _ = try await service.checkAccount(
            containerIdentifier: CloudBackupContainerArgument.deterministicFakeContainerIdentifier
        )
        XCTAssertEqual(transport.calls, ["checkAccount"])
        transport.reset()
        var requestIDs: [String] = []
        let coordinator = RoomProjectPurgeCoordinator(store: store, deletionRequest: { projectID in
            requestIDs.append(projectID)
            try self.writeCanary(at: self.root("DeletionRequests").appendingPathComponent("\(projectID).json"))
        })
        let reaper = RoomTrashReaper(
            store: store, purgeCoordinator: coordinator, clock: FixedRoomProjectClock(date: epoch)
        )

        let report = await reaper.purgeExpiredTrash()

        XCTAssertEqual(report.purgedCount, 1)
        XCTAssertEqual(requestIDs, [saved.projectID], "Automatic purge may write a local request only.")
        XCTAssertTrue(backup.preferences.isEnabled)
        XCTAssertTrue(transport.calls.isEmpty, "No account/list/zone/upload/lookup/download call from purge or reaper.")
        XCTAssertFalse(fileManager.fileExists(atPath: projectURL(saved.projectID).path))
        XCTAssertEqual(try Data(contentsOf: root("DeletionRequests").appendingPathComponent("\(saved.projectID).json")), Self.canary)
        attach("VAL-TRASH-011", "real-purge-zero-fake-transport",
               "Real reaper/purge removed expired package and ran injected journal-only hook. "
               + "Enabled fake cloud service retained; spy positive control passed, then zero transport calls during purge.")
    }

    func testReaperListingFailureIsReportedWithoutInvokingPurge() async throws {
        try writeCanary(at: root("Projects"))
        let spy = TrashRecordingPurger()
        let reaper = RoomTrashReaper(
            store: makeStore(projectIDs: []), purgeCoordinator: spy, clock: FixedRoomProjectClock(date: epoch)
        )

        let report = await reaper.purgeExpiredTrash()

        XCTAssertFalse(try XCTUnwrap(report.listingErrorMessage).isEmpty)
        XCTAssertEqual(report.purgedCount, 0)
        XCTAssertTrue(report.purgeReports.isEmpty)
        XCTAssertTrue(spy.projectIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root("Projects")), Self.canary)
        attach("VAL-TRASH-011", "listing-failure-report",
               "Non-directory package root returned listingErrorMessage, zero reports/count and zero purge invocations.")
    }

    func testLibraryTrashRestoreAndDeleteNowRefreshSummariesAndIndexWithoutManualRefresh() async throws {
        let store = makeStore(projectIDs: ["project-001"])
        let saved = try await saveProject(in: store)
        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        let spy = TrashRecordingPurger(real: RoomProjectPurgeCoordinator(store: store, modelContainer: container))
        let controller = RoomLibraryController(store: store, modelContainer: container, purgeCoordinator: spy)
        await controller.refreshLibrary()
        XCTAssertEqual(controller.summaries, [saved])

        try await controller.moveToTrash(projectID: saved.projectID)

        XCTAssertEqual(controller.summaries.first?.trashedAt, epoch)
        XCTAssertEqual(controller.trashedSummaries.map(\.projectID), [saved.projectID])
        XCTAssertEqual(try indexRecords(container).first?.trashedAt, epoch)
        XCTAssertEqual(controller.summaries.first?.lastRevisedDate, saved.lastRevisedDate)
        try await controller.restoreFromTrash(projectID: saved.projectID)
        XCTAssertEqual(controller.summaries, [saved])
        XCTAssertTrue(controller.trashedSummaries.isEmpty)
        XCTAssertNil(try indexRecords(container).first?.trashedAt)
        try await controller.moveToTrash(projectID: saved.projectID)
        let report = try await controller.deleteNow(projectID: saved.projectID)
        XCTAssertEqual(spy.projectIDs, [saved.projectID], "Delete now must delegate to the injected coordinator.")
        XCTAssertEqual(report.package, .removed)
        XCTAssertTrue(controller.summaries.isEmpty)
        XCTAssertTrue(controller.trashedSummaries.isEmpty)
        XCTAssertTrue(try indexRecords(container).isEmpty)
        XCTAssertNil(controller.libraryErrorMessage)
        XCTAssertNil(controller.indexErrorMessage)
        attach("VAL-TRASH-017", "library-actions-refresh",
               "No refresh between actions: trash projected timestamp, restore returned exact prior summary, "
               + "deleteNow delegated once and removed published summary/index row.")
    }

    func testLibraryIncludesAllStatesAndOrdersTrashByPurgeDateThenProjectID() async throws {
        let ids = ["trash-late", "trash-z-tie", "trash-middle", "trash-a-tie", "active", "archived"]
        let store = makeStore(projectIDs: ids)
        for id in ids {
            _ = try await saveProject(in: store, archived: id == "archived" || id == "trash-a-tie")
        }
        try await trash("trash-late", at: epoch.addingTimeInterval(2 * day))
        try await trash("trash-z-tie", at: epoch)
        try await trash("trash-middle", at: epoch.addingTimeInterval(day))
        try await trash("trash-a-tie", at: epoch)
        let controller = RoomLibraryController(store: store, modelContainer: nil)

        await controller.refreshLibrary()

        XCTAssertEqual(Set(controller.summaries.map(\.projectID)), Set(ids))
        XCTAssertEqual(controller.trashedSummaries.map(\.projectID),
                       ["trash-a-tie", "trash-z-tie", "trash-middle", "trash-late"])
        XCTAssertEqual(controller.summaries.filter { !$0.archived && !$0.isTrashed }.map(\.projectID), ["active"])
        XCTAssertEqual(controller.summaries.filter { $0.archived && !$0.isTrashed }.map(\.projectID), ["archived"])
        let policy = RoomTrashRetentionPolicy()
        XCTAssertEqual(controller.trashedSummaries.compactMap(\.trashedAt).map { policy.purgeDate(trashedAt: $0) },
                       [epoch, epoch, epoch.addingTimeInterval(day), epoch.addingTimeInterval(2 * day)]
                           .map { $0.addingTimeInterval(30 * day) })
        attach("VAL-TRASH-017", "trash-date-order-and-id-tie-break",
               "Listing contains active, archived, trash and archived+trash. Trash order T+0/a,T+0/z,T+1d,T+2d; "
               + "nontrashed Active/Archived membership excludes all four trashed projects.")
    }

    func testFreshIndexRebuildAndExistingRowUpdateProjectTrashStateFromDisk() async throws {
        let store = makeStore(projectIDs: ["active", "trashed"])
        _ = try await saveProject(in: store)
        _ = try await saveProject(in: store)
        let first = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        try await rebuildIndex(store: store, container: first)
        XCTAssertTrue(try indexRecords(first).allSatisfy { $0.trashedAt == nil })
        try await store.moveToTrash(projectID: "trashed")
        try await rebuildIndex(store: store, container: first)
        XCTAssertEqual(try indexRecords(first).first { $0.projectID == "trashed" }?.trashedAt, epoch)
        XCTAssertNil(try indexRecords(first).first { $0.projectID == "active" }?.trashedAt)

        // An independent empty container models discarding the rebuildable
        // index, not a second source of project truth.
        let replacement = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        XCTAssertTrue(try indexRecords(replacement).isEmpty)
        try await rebuildIndex(store: store, container: replacement)
        let rows = try indexRecords(replacement)
        XCTAssertEqual(Set(rows.map(\.projectID)), Set(["active", "trashed"]))
        XCTAssertEqual(rows.first { $0.projectID == "trashed" }?.trashedAt, epoch)
        XCTAssertNil(rows.first { $0.projectID == "active" }?.trashedAt)
        let reopenedStore = LocalRoomProjectStore(rootURL: root("Projects"))
        let reopenedListing = try await reopenedStore.listProjectListing(includeArchived: true, includeTrashed: true)
        XCTAssertEqual(reopenedListing.summaries.first { $0.projectID == "trashed" }?.trashedAt, epoch)
        let metadata = try RoomJSONCoding.makeDecoder().decode(
            RoomMetadata.self, from: Data(contentsOf: projectURL("trashed").appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(metadata.trashedAt, epoch)
        XCTAssertEqual(RoomProjectIndexFactory.persistencePolicy, .localOnly)
        try await store.restoreFromTrash(projectID: "trashed")
        try await rebuildIndex(store: store, container: replacement)
        XCTAssertTrue(try indexRecords(replacement).allSatisfy { $0.trashedAt == nil })
        attach("VAL-TRASH-016", "disk-truth-two-memory-indexes",
               "Existing row updated to disk trashedAt; new empty in-memory index rebuilt identical projection. "
               + "Reopened store and metadata retain epoch; restore clears projected timestamp. Factory localOnly.")
    }

    func testHomeRoomCountExcludesNonfixtureTrashAndPreservesArchivedAndFixtureExclusion() {
        let active = summary("active")
        let archived = summary("archived", archived: true)
        let trashed = summary("trashed", trashedAt: epoch)
        let archivedTrash = summary("archived-trash", archived: true, trashedAt: epoch)
        XCTAssertTrue([active, archived, trashed, archivedTrash].allSatisfy { !$0.tags.contains("fixture") })
        XCTAssertEqual(HomeRoomCount.userVisibleCount(of: [active, archived]), 1,
                       "Preserve the pre-existing archived exclusion; do not count two.")
        XCTAssertEqual(HomeRoomCount.userVisibleCount(of: [active, archived, trashed, archivedTrash]), 1)
        XCTAssertEqual(HomeRoomCount.userVisibleCount(of: [trashed, archivedTrash]), 0)
        var fixture = active
        fixture.projectID = "fixture"
        fixture.tags = ["fixture"]
        XCTAssertEqual(HomeRoomCount.userVisibleCount(of: [active, archived, trashed, archivedTrash, fixture]), 1)
        attach("VAL-TRASH-018", "nonfixture-home-count",
               "Four nonfixture controls: active contributes 1; archived, trash and archived+trash contribute 0. "
               + "Existing fixture-tag exclusion also remains intact. MockRoom UI count is not an oracle.")
    }

    func testTrashClockArgumentRequiresBothIsolationFlagsAndFiniteEpoch() {
        let clockFlag = "--trash-clock=1800014400"
        for arguments in [[clockFlag], ["--ui-testing", clockFlag], ["--reset-local-store", clockFlag],
                          ["--ui-testing", "--reset-local-store"],
                          ["--ui-testing", "--reset-local-store", "--trash-clock="],
                          ["--ui-testing", "--reset-local-store", "--trash-clock=garbage"],
                          ["--ui-testing", "--reset-local-store", "--trash-clock=nan"],
                          ["--ui-testing", "--reset-local-store", "--trash-clock=inf"],
                          ["--ui-testing", "--reset-local-store", "--trash-clock=-inf"],
                          ["--ui-testing", "--reset-local-store", "--trash-clock=1e999"]] {
            XCTAssertTrue(TrashClockArgument.resolve(arguments: arguments) is SystemRoomProjectClock,
                          "Invalid/non-isolated clock override must fall back: \(arguments)")
        }
        for value in ["1800014400", "1800014400.5", "0", "-1"] {
            let clock = TrashClockArgument.resolve(
                arguments: ["--ui-testing", "--reset-local-store", "--trash-clock=\(value)"]
            )
            XCTAssertTrue(clock is FixedRoomProjectClock)
            XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: Double(value)!))
        }
        attach("VAL-TRASH-013", "clock-argument-isolation-and-finiteness",
               "Both isolation flags required; missing/empty/malformed/NaN/infinite/overflow use SystemRoomProjectClock. "
               + "Finite integral/fractional/zero/negative epochs use FixedRoomProjectClock exactly.")
    }

    func testResolvedTrashClockStampsStoreAndDrivesReaperAtExactExpiry() async throws {
        let clock = TrashClockArgument.resolve(
            arguments: ["--ui-testing", "--reset-local-store", "--trash-clock=1800014400"]
        )
        let store = makeStore(projectIDs: ["clock-project"], clock: clock)
        let saved = try await saveProject(in: store)
        try await store.moveToTrash(projectID: saved.projectID)
        let package = try await store.load(projectID: saved.projectID)
        XCTAssertEqual(package.metadata.trashedAt, clock.now())
        XCTAssertEqual(package.metadata.trashedAt, epoch)
        let coordinator = RoomProjectPurgeCoordinator(store: store)
        let initial = RoomTrashReaper(store: store, purgeCoordinator: coordinator, clock: clock)
        let initialReport = await initial.purgeExpiredTrash()
        XCTAssertEqual(initialReport.purgedCount, 0)
        let beforeClock = TrashClockArgument.resolve(
            arguments: ["--ui-testing", "--reset-local-store", "--trash-clock=\(Int(epoch.timeIntervalSince1970 + 30 * day - 1))"]
        )
        let before = await RoomTrashReaper(store: store, purgeCoordinator: coordinator, clock: beforeClock).purgeExpiredTrash()
        XCTAssertEqual(before.purgedCount, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: projectURL(saved.projectID).path))
        let expiryClock = TrashClockArgument.resolve(
            arguments: ["--ui-testing", "--reset-local-store", "--trash-clock=\(Int(epoch.timeIntervalSince1970 + 30 * day))"]
        )

        let expired = await RoomTrashReaper(store: store, purgeCoordinator: coordinator, clock: expiryClock).purgeExpiredTrash()

        XCTAssertEqual(expired.purgedCount, 1)
        XCTAssertEqual(expired.purgeReports.map(\.projectID), [saved.projectID])
        XCTAssertFalse(fileManager.fileExists(atPath: projectURL(saved.projectID).path))
        attach("VAL-TRASH-013", "shared-resolved-clock-store-and-reaper",
               "Resolved epoch stamps real store metadata. Same clock reaper keeps package; resolved +30d-1s keeps it; "
               + "resolved exact +30d purges it. Explicit dependency-injection proof, not UI date/composition proof.")
    }

    func testSceneActivationHelperAwaitsReaperThenRefreshesLibraryFromDisk() async throws {
        let store = makeStore(projectIDs: ["foreground-trash", "active"])
        let trashed = try await saveProject(in: store)
        let active = try await saveProject(in: store)
        try await trash(trashed.projectID, at: epoch.addingTimeInterval(-31 * day))
        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        let controller = RoomLibraryController(store: store, modelContainer: container)
        await controller.refreshLibrary()
        XCTAssertEqual(controller.trashedSummaries.map(\.projectID), [trashed.projectID])
        let oldSummaries = controller.summaries
        let reaper = TrashSuspendedReaper(
            report: .init(purgeReports: [.init(projectID: trashed.projectID, package: .removed)])
        )
        let task = Task {
            await AppEnvironment.purgeExpiredTrashAndRefreshLibrary(reaper: reaper, libraryController: controller)
        }
        defer { reaper.gate.release() }
        await fulfillment(of: [reaper.gate.enteredExpectation], timeout: 10)
        guard reaper.gate.hasEntered else {
            task.cancel()
            return
        }
        XCTAssertEqual(reaper.callCount, 1)
        // Emulate a purge that completed its package work but has not yet
        // returned. Refresh-before-reap is exposed by this suspension gate.
        try await store.permanentlyDelete(projectID: trashed.projectID)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(controller.summaries, oldSummaries, "Must not refresh until awaited reaper returns.")
        XCTAssertEqual(controller.trashedSummaries.map(\.projectID), [trashed.projectID])
        XCTAssertEqual(Set(try indexRecords(container).map(\.projectID)), Set([trashed.projectID, active.projectID]))

        reaper.gate.release()
        let report = await task.value

        XCTAssertEqual(report.purgedCount, 1)
        XCTAssertEqual(report.purgeReports.map(\.projectID), [trashed.projectID])
        XCTAssertEqual(controller.summaries.map(\.projectID), [active.projectID])
        XCTAssertTrue(controller.trashedSummaries.isEmpty)
        XCTAssertEqual(try indexRecords(container).map(\.projectID), [active.projectID])
        attach("VAL-TRASH-012", "unit-scene-helper-await-before-refresh",
               "Unit-level scene orchestration seam: suspended fake reaper entered once; externally deleted package "
               + "stayed in published summaries/index until release. Handler returned reap report and refreshed both afterward. "
               + "Home/scene trigger wiring, task priority and forbidden-token checks require separate source evidence.")
    }

    func testAppEnvironmentComposesTheSameForcedClockForStoreAndReaper() async throws {
        let token = "trash-clock-\(UUID().uuidString)"
        let arguments = ["--ui-testing", "--reset-local-store", "--use-mock-fixture",
                         "--isolated-root-token=\(token)", "--trash-clock=1800014400"]
        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        let environment = AppEnvironment(arguments: arguments, indexContainer: container)
        defer {
            for kind in IsolatedTestRoots.Kind.allCases {
                if let url = IsolatedTestRoots.resolve(
                    kind, arguments: arguments, fileManager: fileManager, wipeOnReset: false
                ), fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedValue = try await environment.libraryController.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedValue)
        try await environment.libraryController.moveToTrash(projectID: saved.projectID)
        XCTAssertEqual(environment.trashClock.now(), epoch)
        XCTAssertEqual(environment.trashReaper.clock.now(), epoch)
        XCTAssertEqual(environment.libraryController.summaries.first?.trashedAt, epoch)
        let report = await environment.purgeExpiredTrashAndRefreshLibrary()
        XCTAssertEqual(report.purgedCount, 0)
        XCTAssertEqual(environment.libraryController.trashedSummaries.map(\.projectID), [saved.projectID])
        attach("VAL-TRASH-013", "actual-app-clock-composition",
               "Real isolated AppEnvironment with in-memory index passes the same fixed epoch to its store and reaper. "
               + "Trashing stamps the forced epoch, and its launch sweep retains unexpired trash.")
    }

    func testCompanionFailureIsANonblockingLibraryWarningAndPackageStaysDeleted() async throws {
        let store = makeStore(projectIDs: ["project-001"])
        let saved = try await saveProject(in: store)
        let source = try await store.redesignSourceRevisionBinding(
            projectID: saved.projectID, revisionID: saved.headRevisionID
        )
        let canary = conceptDirectory(source: source, conceptID: "unowned").appendingPathComponent("keep")
        try writeCanary(at: canary)
        let coordinator = RoomProjectPurgeCoordinator(store: store, conceptStore: makeConceptStore())
        let controller = RoomLibraryController(store: store, modelContainer: nil, purgeCoordinator: coordinator)
        await controller.refreshLibrary()

        let report = try await controller.deleteNow(projectID: saved.projectID)

        XCTAssertTrue(report.packageDeleted)
        XCTAssertTrue(report.hasFailures)
        XCTAssertTrue(controller.summaries.isEmpty)
        XCTAssertTrue(try XCTUnwrap(controller.purgeErrorMessage).contains("Concept Sets"))
        XCTAssertNil(controller.libraryErrorMessage)
        XCTAssertEqual(try Data(contentsOf: canary), Self.canary)
        await controller.refreshLibrary()
        XCTAssertNotNil(controller.purgeErrorMessage)
        XCTAssertTrue(controller.summaries.isEmpty)
        attach("VAL-TRASH-009", "nonblocking-warning-never-resurrects",
               "deleteNow returns successfully after unsafe concept cleanup, publishes a Concept Sets warning, "
               + "preserves unowned canary and never restores the deleted package during refresh.")
    }

    // MARK: - Owned synthetic fixtures

    private func root(_ name: String) -> URL {
        temporaryRoot.appendingPathComponent(name, isDirectory: true)
    }

    private func projectURL(_ projectID: String) -> URL {
        root("Projects").appendingPathComponent(projectID, isDirectory: true)
    }

    private func makeStore(
        projectIDs: [String],
        clock: (any RoomProjectClock)? = nil
    ) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root("Projects"),
            clock: clock ?? FixedRoomProjectClock(date: epoch),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: projectIDs,
                revisionIDs: projectIDs.indices.map { "revision-\($0 + 1)" }
            )
        )
    }

    private func saveProject(in store: LocalRoomProjectStore, archived: Bool = false) async throws -> RoomProjectSummary {
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        var draft = fixture.draft
        draft.metadata.archived = archived
        let saved = try await store.saveDraft(draft, decision: .save, assets: fixture.assets)
        return try XCTUnwrap(saved)
    }

    private func trash(_ projectID: String, at date: Date) async throws {
        let store = LocalRoomProjectStore(rootURL: root("Projects"), clock: FixedRoomProjectClock(date: date))
        try await store.moveToTrash(projectID: projectID)
    }

    private func makeConceptStore() -> LocalRoomConceptStore {
        LocalRoomConceptStore(rootURL: root("ConceptSets"), sourcePackageRootURL: root("Projects"))
    }

    private func conceptDirectory(source: RoomRedesignSourceRevision, conceptID: String) -> URL {
        root("ConceptSets")
            .appendingPathComponent(source.projectID)
            .appendingPathComponent(source.revisionID)
            .appendingPathComponent(source.revisionManifestSHA256)
            .appendingPathComponent(conceptID)
    }

    private func conceptImport(source: RoomRedesignSourceRevision, conceptID: String = "concept-001") -> RoomConceptSetImport {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let attachment = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: png),
            byteCount: UInt64(png.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedLooseFile,
            mapping: .unmatched
        )
        return .init(
            conceptSet: .init(
                conceptSetID: conceptID,
                sourceRevision: source,
                request: "Synthetic trash cleanup concept.",
                scope: .stage,
                provider: nil,
                sourceAIRoomPackage: nil,
                importProvenance: .init(kind: .looseLocalFile, sourceFilename: "synthetic.png"),
                createdAt: epoch,
                importedAt: epoch,
                attachments: [attachment],
                comments: [],
                approvalState: .pending,
                archiveState: .active
            ),
            attachments: [.init(attachmentID: attachment.attachmentID, data: png)]
        )
    }

    private func seedRedesign(
        in redesign: LocalRoomRedesignStore,
        store: LocalRoomProjectStore,
        source: RoomRedesignSourceRevision
    ) async throws {
        let package = try await store.load(projectID: source.projectID)
        let head = try XCTUnwrap(package.revisions.first { $0.manifest.revisionID == source.revisionID })
        let bounds = try RoomSpatialNormalization.bounds(of: head.payload.semanticSnapshot)
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: .init(
                source: .manual,
                confidence: 1,
                entryPositionMeters: bounds.minimum,
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: bounds,
                entryFeatureID: nil,
                referenceWallFeatureID: head.payload.semanticSnapshot.structuralElements.first?.id
            )
        )
        try await redesign.save(
            .init(sourceRevision: source, orientation: orientation, redesignIntent: nil,
                  propertyMembership: nil, conceptMetadata: []),
            expectedSourceRevision: source
        )
        let reopened = try await redesign.load(sourceRevision: source)
        XCTAssertEqual(reopened?.sourceRevision, source)
    }

    private func property(_ id: String, members: [String]) -> RoomPropertyContainerV1 {
        .init(propertyID: id, displayName: id, roomProjectIDs: members, createdAt: epoch, updatedAt: epoch)
    }

    private func syncRecord(for saved: RoomProjectSummary) -> ProfessionalProjectSyncJournalRecord {
        .init(
            localProjectID: saved.projectID,
            hostedProjectID: "prj_0000000000000001",
            acknowledgedLocalHeadRevisionID: saved.headRevisionID,
            acknowledgedHostedHeadRevisionID: "rev_0000000000000001",
            status: .canonical,
            currentHostedHeadRevisionID: "rev_0000000000000001",
            canonicalRevisionID: "rev_0000000000000001"
        )
    }

    private func seedPublishedOperation(
        source: RoomRedesignSourceRevision
    ) async throws -> (journal: PublicationOperationJournal, record: PublicationOperationJournalRecord, url: URL) {
        var options = RoomPublicationReviewOptions.default(now: epoch)
        options.title = "Synthetic trash audit"
        options.branding = .init(
            businessName: "Synthetic studio", phone: "+1 555 0100",
            website: "https://example.invalid", accent: .blueprint, logo: nil
        )
        let fixture = try RoomPublicationFixtureFactory.makeInput(options: options, includeWarning: false)
        let roomKey = try XCTUnwrap(fixture.sourceBindings.first?.publicRoomKey)
        let input = RoomPublicationReviewInput(
            journalAnchorProjectID: source.projectID,
            draft: fixture.draft,
            sourceBindings: [.init(publicRoomKey: roomKey, sourceRevision: source)],
            hostedSourceBindings: [.init(
                publicRoomKey: roomKey, projectPublicID: "prj_0000000000000001",
                revisionPublicID: "rev_0000000000000001", sourceRevision: source
            )],
            propertyCuration: nil,
            assets: fixture.assets,
            rasterChoices: fixture.rasterChoices,
            conceptChoices: fixture.conceptChoices,
            aiReadyPackageChoices: fixture.aiReadyPackageChoices,
            qualityWarnings: fixture.qualityWarnings
        )
        let preparation = try await RoomPublishedSnapshotBuilder.prepare(
            draft: input.draft, sourceBindings: input.sourceBindings, assets: input.assets
        )
        let approval = preparation.makeApproval(reviewID: "trash-audit-review-001", reviewedAt: epoch)
        try fileManager.createDirectory(at: root("PublicationArchiveWorkspace"), withIntermediateDirectories: false)
        let archive = try await RoomPublicationArchive.build(
            ready: preparation.finalize(approval: approval),
            archiveURL: temporaryRoot.appendingPathComponent("synthetic-publication.zip"),
            workspaceURL: root("PublicationArchiveWorkspace")
        )
        var record = try PublicationOperationJournalRecord.prepared(
            operationID: "trash-audit-operation-001",
            input: input,
            preparation: preparation,
            approval: approval,
            archiveManifestSHA256: RoomSHA256.hexDigest(of: archive.manifestData),
            archiveSHA256: archive.receipt.archiveSHA256,
            archiveByteCount: archive.receipt.archiveByteCount
        )
        let journal = try PublicationOperationJournal(rootURL: root("PublicationOperationJournal"))
        try journal.replace(record)
        try record.markAllocated(.init(
            allocationID: "pua_0000000000000001", allocationExpiresAt: epoch.addingTimeInterval(600)
        ))
        try journal.replace(record)
        try record.markPublished(snapshotID: "snp_0000000000000001")
        try journal.replace(record)
        return (journal, record, root("PublicationOperationJournal").appendingPathComponent("operations/\(record.operationID).json"))
    }

    private func rebuildIndex(store: LocalRoomProjectStore, container: ModelContainer) async throws {
        let listing = try await store.listProjectListing(includeArchived: true, includeTrashed: true)
        try RoomProjectIndexRebuilder.rebuild(listing: listing, in: ModelContext(container))
    }

    private func indexRecords(_ container: ModelContainer) throws -> [RoomProjectIndexRecord] {
        try ModelContext(container).fetch(FetchDescriptor<RoomProjectIndexRecord>())
    }

    private func summary(_ id: String, archived: Bool = false, trashedAt: Date? = nil) -> RoomProjectSummary {
        .init(
            projectID: id, customName: id, captureDate: epoch, lastRevisedDate: epoch,
            manualLocation: "", tags: [], thumbnailRelativePath: nil,
            archived: archived, headRevisionID: "revision-001", trashedAt: trashedAt
        )
    }

    private func writeCanary(at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.canary.write(to: url, options: .withoutOverwriting)
    }

    private func relativePaths() throws -> [String] {
        try fileManager.subpathsOfDirectory(atPath: temporaryRoot.path).sorted()
    }

    private func bytesUnder(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try fileManager.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[path] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func attach(_ contractID: String, _ slug: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(contractID)-\(slug)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct ConceptOwnership: Codable {
        var formatVersion = "roomscan-concept-store-ownership-v1"
        var sourceRevision: RoomRedesignSourceRevision
        var conceptSetID: String
        var transactionID = "trash-ownership-transaction-001"
    }

    private static let ownershipFilename = ".roomscan-concept-ownership.json"
    private static let canary = Data("synthetic-trash-lifecycle-canary".utf8)
}

private enum TrashLifecycleFailure: LocalizedError {
    case deletionRequest
    case unexpectedTransport

    var errorDescription: String? {
        switch self {
        case .deletionRequest: "Synthetic deletion request failed."
        case .unexpectedTransport: "Unexpected synthetic backup transport invocation."
        }
    }
}

@MainActor
private final class TrashRecordingPurger: RoomProjectPurging {
    private let real: (any RoomProjectPurging)?
    private(set) var projectIDs: [String] = []

    init(real: (any RoomProjectPurging)? = nil) {
        self.real = real
    }

    func purge(projectID: String) async -> RoomProjectPurgeReport {
        projectIDs.append(projectID)
        if let real { return await real.purge(projectID: projectID) }
        return .init(projectID: projectID, package: .removed)
    }
}

@MainActor
private final class TrashLifecycleGate {
    let enteredExpectation = XCTestExpectation(description: "Synthetic trash operation reached its suspension gate.")
    private(set) var hasEntered = false
    private var released = false
    private var suspension: CheckedContinuation<Void, Never>?

    func suspend() async {
        hasEntered = true
        enteredExpectation.fulfill()
        guard !released else { return }
        await withCheckedContinuation { suspension = $0 }
    }

    func release() {
        released = true
        suspension?.resume()
        suspension = nil
    }
}

@MainActor
private final class TrashSuspendedReaper: RoomTrashReaping {
    let gate = TrashLifecycleGate()
    private let report: RoomTrashReaperReport
    private(set) var callCount = 0

    init(report: RoomTrashReaperReport) {
        self.report = report
    }

    func purgeExpiredTrash() async -> RoomTrashReaperReport {
        callCount += 1
        await gate.suspend()
        return report
    }
}

/// The current neutral transport protocol lives in
/// Infrastructure/CloudBackup/RoomCloudBackupService.swift (not a separate
/// RoomCloudBackupTransport.swift). No production transport is constructed.
@MainActor
private final class TrashCloudTransportSpy: RoomCloudBackupTransport {
    private(set) var calls: [String] = []

    func reset() { calls.removeAll() }

    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus {
        calls.append("checkAccount")
        return .available
    }

    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult {
        calls.append("listBackups")
        throw TrashLifecycleFailure.unexpectedTransport
    }

    func ensureBackupZone(containerIdentifier: String) async throws {
        calls.append("ensureBackupZone")
        throw TrashLifecycleFailure.unexpectedTransport
    }

    func save(snapshot: RoomBackupSnapshot, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord {
        calls.append("save")
        throw TrashLifecycleFailure.unexpectedTransport
    }

    func lookup(snapshotID: String, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord? {
        calls.append("lookup")
        throw TrashLifecycleFailure.unexpectedTransport
    }

    func fetchArchive(
        record: RoomCloudBackupRemoteRecord, containerIdentifier: String, into destinationURL: URL
    ) async throws {
        calls.append("fetchArchive")
        throw TrashLifecycleFailure.unexpectedTransport
    }
}
