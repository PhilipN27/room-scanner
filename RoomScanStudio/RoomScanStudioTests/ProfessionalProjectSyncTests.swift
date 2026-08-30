import Foundation
import RoomScanCore
import XCTest
@testable import RoomScanStudio

@MainActor
final class ProfessionalProjectSyncTests: XCTestCase {
    func testConfiguredActionContextRejectsInvalidPolicyAndDeviceInputs() throws {
        XCTAssertThrowsError(try ProfessionalProjectSyncActionContext(
            quotaPolicyVersion: 0,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1,
            deviceID: "device-001"
        ))
        XCTAssertThrowsError(try ProfessionalProjectSyncActionContext(
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1,
            deviceID: "../unsafe-device"
        ))
        XCTAssertEqual(
            try ProfessionalProjectSyncActionContext(
                quotaPolicyVersion: 7,
                hostedGlobalVersion: 11,
                hostedWorkspaceVersion: 13,
                deviceID: "device-001"
            ),
            try ProfessionalProjectSyncActionContext(
                quotaPolicyVersion: 7,
                hostedGlobalVersion: 11,
                hostedWorkspaceVersion: 13,
                deviceID: "device-001"
            )
        )
    }

    func testJournalPersistsOnlyPublicResumableSyncState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-sync-journal-red-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = try ProfessionalProjectSyncJournal(rootURL: root)
        let record = ProfessionalProjectSyncJournalRecord(
            localProjectID: "project-001",
            hostedProjectID: "prj_0000000000000001",
            acknowledgedLocalHeadRevisionID: "revision-001",
            acknowledgedHostedHeadRevisionID: "rev_0000000000000001",
            localDraftHeadRevisionID: "revision-002",
            idempotencyDigest: String(repeating: "a", count: 64),
            status: .allocated
        )

        try journal.replace(record)

        XCTAssertEqual(try journal.load(localProjectID: "project-001"), record)

        let recordURL = root
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("project-001.json")
        let persisted = try Data(contentsOf: recordURL)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("https://"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("Authorization"))
    }

    func testFirstPartyJSONUsesAuthorizationButSignedUploadDoesNot() async throws {
        let http = RecordingSyncHTTPTransport()
        let streams = RecordingSyncFileTransfer()
        let client = try FoundationProfessionalProjectSyncTransport(
            baseURL: URL(string: "https://sync.example.test")!,
            authorization: { "Bearer in-memory-session" },
            http: http,
            fileTransfer: streams
        )
        let request = ProfessionalProjectSyncMigrationRequest(
            sourceProjectID: "project-001",
            proposedRevisionID: "revision-001",
            workingSetManifestSHA256: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64),
            archiveByteCount: 42,
            idempotencyKey: String(repeating: "c", count: 64),
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )

        let allocation = try await client.allocateMigration(request)
        try await client.upload(
            archiveURL: try makeTemporaryArchive(contents: Data("archive".utf8)),
            allocation: allocation
        )

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url.path, "/projects/migration/allocate")
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer in-memory-session")
        XCTAssertNil(streams.uploadHeaders.first?["Authorization"])
        XCTAssertEqual(streams.uploadURLs.first?.scheme, "https")
    }

    func testTransportRejectsUserInfoAndOverLimitBeforeAnySignedTransfer() async throws {
        let streams = RecordingSyncFileTransfer()
        XCTAssertThrowsError(try FoundationProfessionalProjectSyncTransport(
            baseURL: URL(string: "https://user:password@sync.example.test")!,
            authorization: { "Bearer in-memory-session" },
            http: RecordingSyncHTTPTransport(),
            fileTransfer: streams
        ))

        let oversizedHTTP = RecordingSyncHTTPTransport()
        let oversized = try FoundationProfessionalProjectSyncTransport(
            baseURL: URL(string: "https://sync.example.test")!,
            authorization: { "Bearer in-memory-session" },
            http: oversizedHTTP,
            fileTransfer: streams
        )
        await XCTAssertProfessionalSyncThrows {
            _ = try await oversized.allocateMigration(.init(
                sourceProjectID: "project-001",
                proposedRevisionID: "revision-001",
                workingSetManifestSHA256: String(repeating: "a", count: 64),
                archiveSHA256: String(repeating: "b", count: 64),
                archiveByteCount: ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes + 1,
                idempotencyKey: String(repeating: "c", count: 64),
                quotaPolicyVersion: 1,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            ))
        }
        XCTAssertEqual(oversizedHTTP.requests.count, 0)
        XCTAssertTrue(streams.uploadURLs.isEmpty)

        let maliciousHTTP = MaliciousUploadURLHTTPTransport()
        let client = try FoundationProfessionalProjectSyncTransport(
            baseURL: URL(string: "https://sync.example.test")!,
            authorization: { "Bearer in-memory-session" },
            http: maliciousHTTP,
            fileTransfer: streams
        )
        await XCTAssertProfessionalSyncThrows {
            _ = try await client.allocateMigration(.init(
                sourceProjectID: "project-001",
                proposedRevisionID: "revision-001",
                workingSetManifestSHA256: String(repeating: "a", count: 64),
                archiveSHA256: String(repeating: "b", count: 64),
                archiveByteCount: 42,
                idempotencyKey: String(repeating: "c", count: 64),
                quotaPolicyVersion: 1,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            ))
        }
        XCTAssertEqual(maliciousHTTP.requests.count, 1)
        XCTAssertTrue(streams.uploadURLs.isEmpty)

        await XCTAssertProfessionalSyncThrows {
            _ = try await client.allocateRawArchive(.init(
                projectID: "rev_0000000000000001",
                revisionID: "rev_0000000000000001",
                rawManifestSHA256: String(repeating: "a", count: 64),
                archiveSHA256: String(repeating: "b", count: 64),
                archiveByteCount: 42,
                reviewSHA256: String(repeating: "c", count: 64),
                idempotencyKey: String(repeating: "d", count: 64),
                quotaPolicyVersion: 1,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            ))
        }
        XCTAssertEqual(maliciousHTTP.requests.count, 1, "a rev_ value must never be accepted as a hosted project ID")
    }

    func testExplicitRefreshPreservesOfflineLocalDraftWithoutRequestOrDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-sync-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRoomProjectStore(
            rootURL: root.appendingPathComponent("projects", isDirectory: true),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let controller = RoomLibraryController(store: store, modelContainer: nil)
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let before = try await controller.loadPackage(projectID: saved.projectID)
        let journal = try ProfessionalProjectSyncJournal(rootURL: root.appendingPathComponent("journal", isDirectory: true))
        try journal.replace(ProfessionalProjectSyncJournalRecord(
            localProjectID: saved.projectID,
            hostedProjectID: "prj_0000000000000001",
            acknowledgedLocalHeadRevisionID: "older-revision-001",
            acknowledgedHostedHeadRevisionID: "rev_0000000000000001",
            status: .canonical
        ))
        let remote = RecordingProjectSyncRemote()
        let service = ProfessionalProjectSyncService(
            controller: controller,
            modelFactory: nil,
            journal: journal,
            transport: remote,
            scratchRootURL: root.appendingPathComponent("scratch", isDirectory: true)
        )

        let state = try await service.refresh(projectID: saved.projectID)

        XCTAssertEqual(state, .localDraft)
        XCTAssertEqual(remote.requestCount, 0)
        let after = try await controller.loadPackage(projectID: saved.projectID)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try journal.load(localProjectID: saved.projectID)?.localDraftHeadRevisionID, before.manifest.headRevisionID)
    }

    func testTwoIndependentClientsKeepCanonicalAndStaleArchivesRecoverableWithoutMerge() async throws {
        // This is intentionally a real archive/recovery/CAS oracle rather
        // than a lightweight state-machine test. Simulator SHA/ZIP work can
        // exceed XCTest's short default allowance on constrained hosts, so
        // give the bounded test enough time to finish while the peer barrier
        // below still fails independently after 60 seconds.
        executionTimeAllowance = 600
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-two-client-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let clientA = try makeRealSyncClient(
            root: root.appendingPathComponent("client-a", isDirectory: true),
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        // Keep this end-to-end oracle on the real package documents and real
        // asset paths, while avoiding repeated multi-megabyte PNG hashing in
        // every archive/recovery branch. The store treats evidence as opaque
        // bytes; one compact deterministic source therefore exercises the
        // same package, ZIP, download-validation, and promotion boundaries.
        let compactAsset = root.appendingPathComponent("compact-fixture-asset.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("slice-5-two-client-fixture".utf8).write(
            to: compactAsset,
            options: .withoutOverwriting
        )
        let compactAssets = fixture.assets.map {
            RoomAssetInput(
                sourceURL: compactAsset,
                destination: $0.destination,
                scope: $0.scope
            )
        }
        let savedResult = try await clientA.controller.saveMockDraft(
            fixture.draft,
            assets: compactAssets
        )
        let saved = try XCTUnwrap(savedResult)
        let beforeMigration = try await clientA.controller.loadPackage(projectID: saved.projectID)

        let migration = try await clientA.service.previewMigration(projectID: saved.projectID)
        XCTAssertEqual(migration.localRoomDisplayName, beforeMigration.metadata.customName)
        XCTAssertTrue(migration.workingCategories.contains { $0.category == .packageBackup })
        XCTAssertEqual(migration.rawExcludedClasses, RoomProfessionalRawAssetClass.allCases)
        let migrationState = try await clientA.service.approveMigration(
            migration,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        XCTAssertEqual(migrationState, .canonical)
        let afterMigration = try await clientA.controller.loadPackage(projectID: saved.projectID)
        XCTAssertEqual(afterMigration, beforeMigration)

        let clientB = try makeRealSyncClient(
            root: root.appendingPathComponent("client-b", isDirectory: true),
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let recovered = try await clientB.service.recoverHosted(
            projectID: DeterministicHostedProjectSync.projectID,
            target: .original
        )
        XCTAssertFalse(recovered.recoveredAsCopy)
        let recoveryRecord = try XCTUnwrap(
            try clientB.journal.load(localProjectID: recovered.projectSummary.projectID)
        )
        XCTAssertEqual(recoveryRecord.hostedProjectID, DeterministicHostedProjectSync.projectID)
        XCTAssertEqual(recoveryRecord.acknowledgedHostedHeadRevisionID, DeterministicHostedProjectSync.initialRevisionID)
        XCTAssertNil(recoveryRecord.recoveryTransactionID)
        XCTAssertEqual(recoveryRecord.recoveryPhase, .none)

        let localAChild = try await appendHead(
            clientA.controller,
            projectID: saved.projectID,
            revisionID: "revision-a-002"
        )
        let localBChild = try await appendHead(
            clientB.controller,
            projectID: recovered.projectSummary.projectID,
            revisionID: "revision-b-003"
        )
        XCTAssertEqual(localAChild.revisionID, "revision-a-002")
        XCTAssertEqual(localBChild.revisionID, "revision-b-003")

        let canonicalPreview = try await clientA.service.previewMigration(projectID: saved.projectID)
        let stalePreview = try await clientB.service.previewMigration(projectID: saved.projectID)
        // Both allocation requests must observe the same hosted parent. The
        // shared fake enforces expected-head equality at allocation and holds
        // both callers until that check has happened; only final CAS decides
        // canonical versus stale.
        let allocationBarrier = TwoPartyAllocationBarrier()
        await hosted.setAppendAllocationBarrier(allocationBarrier)
        async let first = captureProfessionalSyncOutcome(client: "client-a") {
            try await clientA.service.approveMigration(
                canonicalPreview,
                sessionUnlocked: true,
                quotaPolicyVersion: 1,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            )
        }
        async let second = captureProfessionalSyncOutcome(client: "client-b") {
            try await clientB.service.approveMigration(
                stalePreview,
                sessionUnlocked: true,
                quotaPolicyVersion: 1,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            )
        }
        let outcomes = await [first, second]
        await hosted.setAppendAllocationBarrier(nil)
        let barrierParticipants = await allocationBarrier.arrivedParticipants()
        XCTAssertEqual(
            barrierParticipants,
            ["revision-a-002", "revision-b-003"],
            "both independent clients must allocate against the same hosted parent before either CAS"
        )
        let failures = outcomes.compactMap(\.failureDescription)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " | "))
        let states = outcomes.compactMap(\.state)
        guard states.count == 2 else { return }
        XCTAssertEqual(states.filter { $0 == .canonical }.count, 1)
        guard let staleIndex = states.firstIndex(where: {
            if case .conflict = $0 { return true }
            return false
        }),
        case let .conflict(conflict) = states[staleIndex] else {
            return XCTFail("Expected one explicit preserved stale conflict, got \(states).")
        }
        let canonicalIndex = staleIndex == 0 ? 1 : 0
        let staleClient = [clientA, clientB][staleIndex]
        let stalePreviewForClient = [canonicalPreview, stalePreview][staleIndex]
        let canonicalPreviewForClient = [canonicalPreview, stalePreview][canonicalIndex]
        XCTAssertEqual(conflict.hostedProjectID, DeterministicHostedProjectSync.projectID)
        XCTAssertNotEqual(conflict.canonicalRevisionID, conflict.staleRevisionID)
        let canonicalArchiveValue = await hosted.recoverableArchive(revisionID: conflict.canonicalRevisionID)
        let staleArchiveValue = await hosted.recoverableArchive(revisionID: conflict.staleRevisionID)
        let canonicalArchive = try XCTUnwrap(canonicalArchiveValue)
        let staleArchive = try XCTUnwrap(staleArchiveValue)
        XCTAssertEqual(canonicalArchive.archiveSHA256, canonicalPreviewForClient.archiveSHA256)
        XCTAssertEqual(canonicalArchive.archiveByteCount, canonicalPreviewForClient.archiveByteCount)
        XCTAssertEqual(staleArchive.archiveSHA256, stalePreviewForClient.archiveSHA256)
        XCTAssertEqual(staleArchive.archiveByteCount, stalePreviewForClient.archiveByteCount)
        XCTAssertEqual(canonicalArchive.archive.count, Int(canonicalPreviewForClient.archiveByteCount))
        XCTAssertEqual(staleArchive.archive.count, Int(stalePreviewForClient.archiveByteCount))
        let staleRefresh = try await staleClient.service.refresh(projectID: saved.projectID)
        XCTAssertEqual(staleRefresh, .conflict(conflict), "a relaunch must not hide a persisted stale candidate as localDraft")

        let comparison = try await staleClient.service.compare(conflict)
        XCTAssertTrue(comparison.differs)
        XCTAssertNotEqual(comparison.canonicalPackageManifestSHA256, comparison.stalePackageManifestSHA256)
        XCTAssertEqual(comparison.canonicalSourceSemanticSHA256.count, 64)
        XCTAssertEqual(comparison.staleSourceSemanticSHA256.count, 64)

        let rebase = try await staleClient.service.startRebaseFromHostedHead(conflict)
        XCTAssertTrue(rebase.recoveredAsCopy)
        XCTAssertTrue(rebase.conceptSourcePackageProvenance.isEmpty, "copy recovery must never install original-only AI package provenance")
        let rebaseRefresh = try await staleClient.service.refresh(projectID: rebase.projectSummary.projectID)
        XCTAssertEqual(rebaseRefresh, .awaitingUserEdit)
        let rebasedRecord = try XCTUnwrap(
            try staleClient.journal.load(localProjectID: rebase.projectSummary.projectID)
        )
        XCTAssertNil(rebasedRecord.hostedProjectID)
        XCTAssertNil(rebasedRecord.acknowledgedHostedHeadRevisionID)
        XCTAssertNil(rebasedRecord.recoveryTransactionID)

        let hostedWritesBeforeDuplicate = await hosted.uploadCountValue()
        let duplicate = try await staleClient.service.recoverBranchAsDuplicate(conflict)
        XCTAssertTrue(duplicate.recoveredAsCopy)
        XCTAssertTrue(duplicate.conceptSourcePackageProvenance.isEmpty)
        let duplicateRecord = try XCTUnwrap(
            try staleClient.journal.load(localProjectID: duplicate.projectSummary.projectID)
        )
        XCTAssertNil(duplicateRecord.hostedProjectID, "duplicate recovery is local-only until a separate explicit migration")
        let duplicatePreview = try await staleClient.service.previewMigration(projectID: duplicate.projectSummary.projectID)
        XCTAssertEqual(duplicatePreview.localProjectID, duplicate.projectSummary.projectID)
        let hostedWritesAfterDuplicate = await hosted.uploadCountValue()
        XCTAssertEqual(hostedWritesAfterDuplicate, hostedWritesBeforeDuplicate)
    }

    func testInterruptedImmutablePutReconcilesViaStatusAndCompleteWithoutBlindSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-put-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        await hosted.failNextUploadAfterPersistOnce()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let preview = try await client.service.previewMigration(projectID: saved.projectID)

        let completion = try await client.service.approveMigration(
            preview,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        XCTAssertEqual(completion, .canonical)
        let uploadCount = await hosted.uploadCountValue()
        let statusCount = await hosted.statusCountValue()
        let recoverable = await hosted.recoverableArchive(revisionID: DeterministicHostedProjectSync.initialRevisionID)
        XCTAssertEqual(uploadCount, 1)
        XCTAssertGreaterThanOrEqual(statusCount, 1)
        XCTAssertNotNil(recoverable)
    }

    func testNetworkFailureBeforePersistRetainsPreviewForExactRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-put-network-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        await hosted.failNextUploadBeforePersistOnce()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let preview = try await client.service.previewMigration(projectID: saved.projectID)

        do {
            _ = try await client.service.approveMigration(
                preview,
                sessionUnlocked: true,
                quotaPolicyVersion: 1,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            )
            XCTFail("A pre-persist network failure must retain retry state rather than complete.")
        } catch {
            XCTAssertFalse(error is ProfessionalProjectSyncError && error as? ProfessionalProjectSyncError == .signedUploadPreconditionFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.stagedArchiveURL.path))
        XCTAssertEqual(try client.journal.load(localProjectID: saved.projectID)?.status, .allocated)

        let retryCompletion = try await client.service.retryMigration(
            preview,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        XCTAssertEqual(retryCompletion, .canonical)
        let uploadCount = await hosted.uploadCountValue()
        XCTAssertEqual(uploadCount, 2)
    }

    func testReleaseLeaseRetainsTokenAfterTransientFailureForExactRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-lease-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        await hosted.failNextReleaseOnce()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        _ = try await client.service.acquireLease(
            projectID: DeterministicHostedProjectSync.projectID,
            deviceID: "device-001",
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        do {
            try await client.service.releaseLease(
                projectID: DeterministicHostedProjectSync.projectID,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            )
            XCTFail("Expected transient release failure.")
        } catch {}
        try await client.service.releaseLease(
            projectID: DeterministicHostedProjectSync.projectID,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        let releaseCount = await hosted.releaseCountValue()
        XCTAssertEqual(releaseCount, 2)
        await XCTAssertProfessionalSyncThrows {
            _ = try await client.service.renewLease(
                projectID: DeterministicHostedProjectSync.projectID,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            )
        }
    }

    func testPreviewIsSideEffectFreeAndCancelPreservesSourceAndJournalIdle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-preview-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let before = try await client.controller.loadPackage(projectID: saved.projectID)

        let preview = try await client.service.previewMigration(projectID: saved.projectID)
        XCTAssertNil(try client.journal.load(localProjectID: saved.projectID))
        let previewUploadCount = await hosted.uploadCountValue()
        let previewStatusCount = await hosted.statusCountValue()
        XCTAssertEqual(previewUploadCount, 0)
        XCTAssertEqual(previewStatusCount, 0)
        try client.service.discardMigrationPreview(preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.stagedArchiveURL.path))
        let after = try await client.controller.loadPackage(projectID: saved.projectID)
        XCTAssertEqual(after, before)

        let recreated = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: [],
            revisionIDs: []
        )
        let refreshed = try await recreated.service.refresh(projectID: saved.projectID)
        XCTAssertEqual(refreshed, .idle)
        let relaunchUploadCount = await hosted.uploadCountValue()
        let relaunchStatusCount = await hosted.statusCountValue()
        XCTAssertEqual(relaunchUploadCount, 0)
        XCTAssertEqual(relaunchStatusCount, 0)
    }

    func testOwnedScratchOrphanIsRemovedButUnownedStageFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-scratch-ownership-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let scratch = root.appendingPathComponent("sync-scratch", isDirectory: true)
        let owned = scratch.appendingPathComponent(".roomscan-professional-sync-stage-owned-orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try Data("roomscan-professional-sync-stage-v1".utf8).write(
            to: owned.appendingPathComponent(".roomscan-professional-sync-stage-v1")
        )

        let preview = try await client.service.previewMigration(projectID: saved.projectID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        try client.service.discardMigrationPreview(preview)

        let unowned = scratch.appendingPathComponent(".roomscan-professional-sync-stage-unowned", isDirectory: true)
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: false)
        let relaunched = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: [],
            revisionIDs: []
        )
        await XCTAssertProfessionalSyncThrows {
            _ = try await relaunched.service.previewMigration(projectID: saved.projectID)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unowned.path))
        let orphanUploadCount = await hosted.uploadCountValue()
        XCTAssertEqual(orphanUploadCount, 0)
    }

    func testReviewedRawAttachmentUsesSeparateTierAndNeverAdvancesHead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-raw-attachment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let migration = try await client.service.previewMigration(projectID: saved.projectID)
        let migrationState = try await client.service.approveMigration(
            migration,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        XCTAssertEqual(migrationState, .canonical)
        let hostedHeadBeforeRaw = await hosted.currentRevisionIDValue()
        let headBeforeRaw = try XCTUnwrap(hostedHeadBeforeRaw)
        let package = try await client.controller.loadPackage(projectID: saved.projectID)
        let source = try await client.controller.redesignSourceBinding(
            projectID: saved.projectID,
            revisionID: package.manifest.headRevisionID
        )
        let rawSnapshot = try await makeReviewedRawSnapshot(
            root: root.appendingPathComponent("reviewed-raw", isDirectory: true),
            sourceRevision: source
        )
        let rawStatus = try await client.service.uploadRawArchive(
            rawSnapshot,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        XCTAssertEqual(rawStatus, .attached)
        let hostedHeadAfterRaw = await hosted.currentRevisionIDValue()
        let recoverableHead = await hosted.recoverableArchive(revisionID: headBeforeRaw)
        XCTAssertEqual(hostedHeadAfterRaw, Optional(headBeforeRaw))
        XCTAssertNotNil(recoverableHead)
    }

    func testCorruptRecoveryStaysOutsideLivePackagePromotionBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-corrupt-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let source = try makeRealSyncClient(
            root: root.appendingPathComponent("source", isDirectory: true),
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await source.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let migration = try await source.service.previewMigration(projectID: saved.projectID)
        _ = try await source.service.approveMigration(
            migration,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        let target = try makeRealSyncClient(
            root: root.appendingPathComponent("target", isDirectory: true),
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        await hosted.corruptNextDownloadOnce()
        await XCTAssertProfessionalSyncThrows {
            _ = try await target.service.recoverHosted(
                projectID: DeterministicHostedProjectSync.projectID,
                target: .original
            )
        }
        await XCTAssertProfessionalSyncThrows {
            _ = try await target.controller.loadPackage(projectID: saved.projectID)
        }
        XCTAssertNil(try target.journal.load(localProjectID: saved.projectID))
    }

    func testLostJournalCanonicalExactRetryRebindsPublicHeadsWithoutSecondPut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-lost-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let firstPreview = try await client.service.previewMigration(projectID: saved.projectID)
        let firstResult = try await client.service.approveMigration(
            firstPreview,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        XCTAssertEqual(firstResult, .canonical)
        try client.journal.remove(localProjectID: saved.projectID)

        let retryPreview = try await client.service.previewMigration(projectID: saved.projectID)
        XCTAssertEqual(retryPreview.archiveSHA256, firstPreview.archiveSHA256)
        let retryResult = try await client.service.retryMigration(
            retryPreview,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        XCTAssertEqual(retryResult, .canonical)
        let terminalRetryUploadCount = await hosted.uploadCountValue()
        XCTAssertEqual(terminalRetryUploadCount, 1, "terminal allocation retries must not reuse a signed PUT")
        let rebound = try XCTUnwrap(try client.journal.load(localProjectID: saved.projectID))
        XCTAssertEqual(rebound.hostedProjectID, DeterministicHostedProjectSync.projectID)
        XCTAssertEqual(rebound.acknowledgedHostedHeadRevisionID, DeterministicHostedProjectSync.initialRevisionID)
    }

    func testChangedPreviewInputIsRejectedBeforeAnyHostedAllocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-changed-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001", "revision-002"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let preview = try await client.service.previewMigration(projectID: saved.projectID)
        _ = try await appendHead(
            client.controller,
            projectID: saved.projectID,
            revisionID: "revision-002"
        )
        await XCTAssertProfessionalSyncThrows {
            _ = try await client.service.approveMigration(
                preview,
                sessionUnlocked: true,
                quotaPolicyVersion: 1,
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            )
        }
        let changedUploadCount = await hosted.uploadCountValue()
        let changedStatusCount = await hosted.statusCountValue()
        XCTAssertEqual(changedUploadCount, 0)
        XCTAssertEqual(changedStatusCount, 0)
    }

    func testLeaseRejectsExpiredBoundedResponseWithoutBlockingLocalWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-expired-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        await hosted.setLeaseExpiryOffset(-1)
        let client = try makeRealSyncClient(
            root: root,
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        await XCTAssertProfessionalSyncThrows {
            _ = try await client.service.acquireLease(
                projectID: DeterministicHostedProjectSync.projectID,
                deviceID: "device-001",
                hostedGlobalVersion: 1,
                hostedWorkspaceVersion: 1
            )
        }
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await client.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let local = try await client.service.refresh(projectID: saved.projectID)
        XCTAssertEqual(local, .idle)
    }

    func testInterruptedCompanionRecoveryResumesBoundTransactionAndCleansJournal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("professional-companion-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = DeterministicHostedProjectSync()
        let source = try makeRealSyncClient(
            root: root.appendingPathComponent("source", isDirectory: true),
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await source.controller.saveMockDraft(fixture.draft, assets: fixture.assets)
        let saved = try XCTUnwrap(savedResult)
        let preview = try await source.service.previewMigration(projectID: saved.projectID)
        _ = try await source.service.approveMigration(
            preview,
            sessionUnlocked: true,
            quotaPolicyVersion: 1,
            hostedGlobalVersion: 1,
            hostedWorkspaceVersion: 1
        )
        let target = try makeRealSyncClient(
            root: root.appendingPathComponent("target", isDirectory: true),
            hosted: hosted,
            projectIDs: ["project-001"],
            revisionIDs: ["revision-001"]
        )
        let recovery = try await hosted.allocateRecovery(
            projectID: DeterministicHostedProjectSync.projectID,
            revisionID: DeterministicHostedProjectSync.initialRevisionID
        )
        let archiveURL = root.appendingPathComponent("downloaded-working-set.zip")
        try await hosted.download(recovery, to: archiveURL)
        let faulting = try target.modelFactory.makeProfessionalRecoveryCoordinator(
            scratchRootURL: root
                .appendingPathComponent("target", isDirectory: true)
                .appendingPathComponent("sync-scratch", isDirectory: true)
                .appendingPathComponent("recovery", isDirectory: true),
            journal: target.journal,
            faultInjector: FailingRoomProfessionalRecoveryFaultInjector(
                point: .afterDurablePackageCommitBeforeFirstCompanion
            )
        )
        await XCTAssertProfessionalSyncThrows {
            _ = try await faulting.recoverDownloadedArchive(
                archiveURL: archiveURL,
                recovery: recovery.recovery,
                target: .original
            )
        }
        let interrupted = try XCTUnwrap(try target.journal.load(localProjectID: saved.projectID))
        XCTAssertNotNil(interrupted.recoveryTransactionID)
        XCTAssertEqual(interrupted.hostedProjectID, DeterministicHostedProjectSync.projectID)
        XCTAssertEqual(interrupted.acknowledgedHostedHeadRevisionID, DeterministicHostedProjectSync.initialRevisionID)
        let recoveryReady = try await target.service.refresh(projectID: saved.projectID)
        XCTAssertEqual(recoveryReady, .recoveryReady)

        let result = try await target.service.resumeRecovery(
            localProjectID: saved.projectID
        )
        XCTAssertEqual(result.projectSummary.projectID, saved.projectID)
        let completed = try XCTUnwrap(try target.journal.load(localProjectID: saved.projectID))
        XCTAssertNil(completed.recoveryTransactionID)
        XCTAssertEqual(completed.recoveryPhase, .none)

        // Simulate process death after Core discarded its completed scratch
        // transaction but before the final app-journal clear. The exact stale
        // acknowledgement is safe to clear on `transactionNotFound`; it must
        // not leave a relaunch permanently in recoveryReady.
        var postDiscard = completed
        postDiscard.recoveryTransactionID = result.transaction.transactionID
        postDiscard.recoveryPhase = .companionsCommitted
        try target.journal.replace(postDiscard)
        await XCTAssertProfessionalSyncThrows {
            _ = try await target.service.resumeRecovery(
                localProjectID: saved.projectID
            )
        }
        let postRestart = try XCTUnwrap(try target.journal.load(localProjectID: saved.projectID))
        XCTAssertNil(postRestart.recoveryTransactionID)
        XCTAssertEqual(postRestart.recoveryPhase, .none)
        let postRestartState = try await target.service.refresh(projectID: saved.projectID)
        XCTAssertEqual(postRestartState, .canonical)
    }

    /// Exercises the real guest app composition rather than a test-only local
    /// store. The default-off factory has no hosted builder, so every scan,
    /// save, view, edit, export, and local Concept import below proves no
    /// professional/auth client can be constructed or asked to send a request.
    func testGuestScanSaveViewEditExportAndImportStayAccountFreeAndOffline() async {
        do {
            try await exerciseGuestScanSaveViewEditExportAndImport()
        } catch {
            XCTFail("Guest offline integration failed: \(String(reflecting: error))")
        }
    }

    private func exerciseGuestScanSaveViewEditExportAndImport() async throws {
        let arguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-simulated-capture",
            "--use-mock-fixture",
        ]
        // Resolve the resettable root before any guest data exists. Resolving
        // it again after save would deliberately erase the live project.
        let projectRoot = RoomProjectRootResolver.resolve(
            arguments: arguments,
            fileManager: .default
        )
        defer { resetGuestOfflineRoots(arguments: arguments) }
        let environment = try await guestSyncStage("environment") {
            AppEnvironment(arguments: arguments)
        }
        let factory = environment.professionalEnvironmentFactory
        XCTAssertFalse(factory.hasConstructedEnvironment)
        XCTAssertFalse(factory.hasConstructedProjectSyncService)

        try await guestSyncStage("capture") {
            let capture = environment.acquireCaptureCoordinator()
            capture.prepare()
            try await awaitGuestCapturePhase(capture, .ready)
            capture.start()
            try await awaitGuestCapturePhase(capture, .scanning)
            capture.stop()
            try await awaitGuestCapturePhase(capture, .review)
            capture.roomName = "Offline task five room"
            capture.save()
            try await awaitGuestCapturePhase(capture, .saved)
            environment.releaseCaptureCoordinator(capture)
        }

        let guestProject = try await guestSyncStage("view-edit-export") { () async throws -> (RoomProjectSummary, RoomRevisionManifest) in
            await environment.libraryController.refreshLibrary()
            let summary = try XCTUnwrap(environment.libraryController.summaries.first)
            let viewed = try await environment.libraryController.loadPackage(projectID: summary.projectID)
            let original = try XCTUnwrap(viewed.revisions.last)
            var editor = try RoomRevisionEditor(payload: original.payload)
            try editor.renameElement(id: "simulated-table-001", label: "Guest local edit")
            let edited = try await environment.libraryController.commitEditRevision(
                projectID: summary.projectID,
                expectedHeadRevisionID: viewed.manifest.headRevisionID,
                payload: editor.payload
            )
            await environment.exportCoordinator.prepare(
                projectID: summary.projectID,
                expectedHeadRevisionID: edited.revisionID
            )
            let exported = try XCTUnwrap(environment.exportCoordinator.readyResult)
            XCTAssertTrue(FileManager.default.fileExists(atPath: exported.archiveURL.path))
            await environment.exportCoordinator.completeShare(completed: false)
            return (summary, edited)
        }

        let source = try await guestSyncStage("source-binding") {
            try await environment.libraryController.redesignSourceBinding(
                projectID: guestProject.0.projectID,
                revisionID: guestProject.1.revisionID
            )
        }
        let importRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "professional-guest-import-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: importRoot) }
        let looseConceptURL = try await guestSyncStage("concept-source") {
            try FileManager.default.createDirectory(
                at: importRoot,
                withIntermediateDirectories: true
            )
            let thumbnail = try XCTUnwrap(
                environment.libraryController.thumbnailDataByProjectID[guestProject.0.projectID]
            )
            let url = importRoot.appendingPathComponent("captured-room-thumbnail.png")
            try thumbnail.write(to: url, options: .withoutOverwriting)
            return url
        }
        let importStore = LocalRoomConceptStore(
            rootURL: importRoot.appendingPathComponent("concepts", isDirectory: true),
            sourcePackageRootURL: projectRoot
        )
        let importCoordinator = RoomConceptImportCoordinator(
            store: importStore,
            scratchRootURL: importRoot.appendingPathComponent("scratch", isDirectory: true),
            makeIdentifier: { "guest-local-import" }
        )
        let imported = try await guestSyncStage("concept-import") {
            try await importCoordinator.importLoose(
                from: looseConceptURL,
                request: "Local reference",
                scope: .stage,
                context: .init(expectedSourceRevision: source, currentCanonicalCameraIDs: [])
            )
        }
        XCTAssertEqual(imported.importProvenance.kind, .looseLocalFile)

        XCTAssertThrowsError(try factory.professionalProjectSyncService())
        XCTAssertFalse(factory.hasConstructedEnvironment)
        XCTAssertFalse(factory.hasConstructedProjectSyncService)
        XCTAssertEqual(factory.state, .notEntered)
    }
}

private final class RecordingSyncHTTPTransport: ProfessionalHTTPTransport, @unchecked Sendable {
    private(set) var requests: [ProfessionalHTTPRequest] = []

    func send(_ request: ProfessionalHTTPRequest) async throws -> ProfessionalHTTPResponse {
        requests.append(request)
        let allocationExpiresAt = freshAllocationExpiration()
        return ProfessionalHTTPResponse(
            data: Data("""
            {"status":"allocated","projectID":"prj_0000000000000001","uploadID":"upl_0000000000000001","candidateRevisionID":"rev_0000000000000001","archiveSHA256":"\(String(repeating: "b", count: 64))","archiveByteCount":42,"allocationExpiresAt":"\(allocationExpiresAt)","uploadURL":"https://objects.example.test/upload","uploadHeaders":{"content-type":"application/zip"}}
            """.utf8),
            statusCode: 200
        )
    }
}

private final class MaliciousUploadURLHTTPTransport: ProfessionalHTTPTransport, @unchecked Sendable {
    private(set) var requests: [ProfessionalHTTPRequest] = []

    func send(_ request: ProfessionalHTTPRequest) async throws -> ProfessionalHTTPResponse {
        requests.append(request)
        let allocationExpiresAt = freshAllocationExpiration()
        return .init(
            data: Data("""
            {"status":"allocated","projectID":"prj_0000000000000001","uploadID":"upl_0000000000000001","candidateRevisionID":"rev_0000000000000001","archiveSHA256":"\(String(repeating: "b", count: 64))","archiveByteCount":42,"allocationExpiresAt":"\(allocationExpiresAt)","uploadURL":"https://user:password@objects.example.test/upload","uploadHeaders":{"content-type":"application/zip"}}
            """.utf8),
            statusCode: 200
        )
    }
}

private final class RecordingSyncFileTransfer: ProfessionalFileStreamingTransport, @unchecked Sendable {
    private(set) var uploadURLs: [URL] = []
    private(set) var uploadHeaders: [[String: String]] = []

    func uploadFile(
        at fileURL: URL,
        to url: URL,
        method: String,
        headers: [String: String]
    ) async throws -> ProfessionalFileTransferResponse {
        uploadURLs.append(url)
        uploadHeaders.append(headers)
        XCTAssertEqual(method, "PUT")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        return ProfessionalFileTransferResponse(statusCode: 200)
    }

    func downloadFile(from url: URL, to destinationURL: URL) async throws -> ProfessionalFileTransferResponse {
        XCTFail("Download is not expected in this test.")
        return ProfessionalFileTransferResponse(statusCode: 500)
    }
}

private func makeTemporaryArchive(contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("professional-sync-transport-\(UUID().uuidString).zip")
    try contents.write(to: url, options: .withoutOverwriting)
    return url
}

private final class RecordingProjectSyncRemote: ProfessionalProjectSyncTransport, @unchecked Sendable {
    private(set) var requestCount = 0

    func allocateMigration(_ request: ProfessionalProjectSyncMigrationRequest) async throws -> ProfessionalProjectSyncUploadAllocation { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func allocateRevision(_ request: ProfessionalProjectSyncRevisionRequest) async throws -> ProfessionalProjectSyncUploadAllocation { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func upload(archiveURL: URL, allocation: ProfessionalProjectSyncUploadAllocation) async throws { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func complete(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func uploadStatus(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func allocateRecovery(projectID: String, revisionID: String?) async throws -> ProfessionalProjectSyncRecoveryDownload { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func download(_ recovery: ProfessionalProjectSyncRecoveryDownload, to destinationURL: URL) async throws { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func acquireLease(_ request: ProfessionalProjectSyncLeaseRequest) async throws -> ProfessionalProjectSyncLease { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func renewLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func releaseLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func configureRawArchive(projectID: String, reviewSHA256: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncRawConfiguration { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
    func allocateRawArchive(_ request: ProfessionalProjectSyncRawArchiveRequest) async throws -> ProfessionalProjectSyncUploadAllocation { requestCount += 1; throw ProfessionalProjectSyncError.unavailable }
}

@MainActor
private struct RealSyncClient {
    let controller: RoomLibraryController
    let modelFactory: RoomAIRedesignModelFactory
    let journal: ProfessionalProjectSyncJournal
    let service: ProfessionalProjectSyncService
}

@MainActor
private func makeRealSyncClient(
    root: URL,
    hosted: DeterministicHostedProjectSync,
    projectIDs: [String],
    revisionIDs: [String]
) throws -> RealSyncClient {
    let projects = root.appendingPathComponent("projects", isDirectory: true)
    let redesign = root.appendingPathComponent("redesign", isDirectory: true)
    let concepts = root.appendingPathComponent("concepts", isDirectory: true)
    let store = LocalRoomProjectStore(
        rootURL: projects,
        idGenerator: DeterministicRoomProjectIDGenerator(
            projectIDs: projectIDs,
            revisionIDs: revisionIDs
        )
    )
    let controller = RoomLibraryController(
        store: store,
        modelContainer: nil,
        redesignStore: LocalRoomRedesignStore(rootURL: redesign)
    )
    let factory = RoomAIRedesignModelFactory(
        controller: controller,
        workspaceFactory: RoomExportWorkspaceFactory(
            rootURL: root.appendingPathComponent("export", isDirectory: true)
        ),
        projectRootURL: projects,
        conceptRootURL: concepts,
        conceptImportScratchRootURL: root.appendingPathComponent("concept-import", isDirectory: true),
        provenanceRootURL: root.appendingPathComponent("provenance", isDirectory: true)
    )
    let journal = try ProfessionalProjectSyncJournal(
        rootURL: root.appendingPathComponent("journal", isDirectory: true)
    )
    let service = ProfessionalProjectSyncService(
        controller: controller,
        modelFactory: factory,
        journal: journal,
        transport: hosted,
        scratchRootURL: root.appendingPathComponent("sync-scratch", isDirectory: true),
        waitForPoll: { _ in }
    )
    return .init(
        controller: controller,
        modelFactory: factory,
        journal: journal,
        service: service
    )
}

@MainActor
private func appendHead(
    _ controller: RoomLibraryController,
    projectID: String,
    revisionID: String
) async throws -> RoomRevisionManifest {
    let package = try await controller.loadPackage(projectID: projectID)
    let payload = try XCTUnwrap(package.revisions.last?.payload)
    return try await controller.commitEditRevision(
        projectID: projectID,
        expectedHeadRevisionID: package.manifest.headRevisionID,
        payload: payload,
        newRevisionID: revisionID
    )
}

private func makeReviewedRawSnapshot(
    root: URL,
    sourceRevision: RoomRedesignSourceRevision
) async throws -> RoomProfessionalRawArchiveSnapshot {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("reviewed-rgb.bin")
    try Data("reviewed raw test bytes".utf8).write(to: sourceURL)
    let input = try RoomProfessionalRawArchiveInput(
        assetID: "raw-rgb-00001",
        assetClass: .rgb,
        sourceURL: sourceURL,
        archivePath: "raw/rgb-00001.bin",
        mediaType: "application/octet-stream"
    )
    let selection = try await RoomProfessionalRawArchive.selectionSHA256(
        sourceRevision: sourceRevision,
        inputs: [input]
    )
    let review = try RoomRawDisclosureReview(
        reviewID: "raw-review-00001",
        sourceRevision: sourceRevision,
        reviewedSelectionSHA256: selection,
        reviewedAt: Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)
        ),
        decision: .accepted
    )
    return try await RoomProfessionalRawArchive.build(
        sourceRevision: sourceRevision,
        review: review,
        inputs: [input],
        archiveURL: root.appendingPathComponent("reviewed-raw.zip")
    )
}

private enum DeterministicHostedSyncError: Error {
    case transientNetworkFailure
}

private enum TwoPartyAllocationBarrierError: Error, CustomStringConvertible {
    case duplicateParticipant(String)
    case timedOut(participant: String, arrivals: [String])

    var description: String {
        switch self {
        case let .duplicateParticipant(participant):
            "Duplicate two-client allocation participant: \(participant)"
        case let .timedOut(participant, arrivals):
            "Two-client allocation barrier timed out for \(participant); arrivals=\(arrivals)"
        }
    }
}

private enum CapturedProfessionalSyncOutcome: Sendable {
    case state(ProfessionalProjectSyncPresentationState)
    case failure(client: String, description: String)

    var state: ProfessionalProjectSyncPresentationState? {
        guard case let .state(state) = self else { return nil }
        return state
    }

    var failureDescription: String? {
        guard case let .failure(client, description) = self else { return nil }
        return "\(client): \(description)"
    }
}

private actor TwoPartyAllocationBarrier {
    private var arrivals: Set<String> = []

    func arrive(participant: String) async throws {
        guard arrivals.insert(participant).inserted else {
            throw TwoPartyAllocationBarrierError.duplicateParticipant(participant)
        }
        // Archive construction is deliberately real and can take tens of
        // seconds in a Simulator. Bound only the peer-arrival phase so an
        // early failure cannot leave the other logical client suspended
        // forever or hide which client reached allocation.
        for _ in 0..<1_200 {
            if arrivals.count == 2 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TwoPartyAllocationBarrierError.timedOut(
            participant: participant,
            arrivals: arrivals.sorted()
        )
    }

    func arrivedParticipants() -> [String] {
        arrivals.sorted()
    }
}

/// Public-route fake only: bytes are real Core working archives built by each
/// client service, while this shared host models immutable allocation/status/
/// recovery behavior and never reimplements archive validation.
private actor DeterministicHostedProjectSync: ProfessionalProjectSyncTransport {
    static let projectID = "prj_0000000000000001"
    static let initialRevisionID = "rev_0000000000000001"

    private struct Upload {
        let projectID: String
        let uploadID: String
        let candidateRevisionID: String
        let expectedHostedHeadRevisionID: String?
        let workingSetManifestSHA256: String
        let archiveSHA256: String
        let archiveByteCount: UInt64
        let isRaw: Bool
        var archive: Data?
        var completed: Bool
        var terminalStatus: ProfessionalProjectSyncStatus?
    }

    private var uploads: [String: Upload] = [:]
    private var allocationByIdempotency: [String: String] = [:]
    private var archiveByRevision: [String: Upload] = [:]
    private var nextRevisionNumber = 1
    private var nextUploadNumber = 1
    private var currentRevisionID: String?
    private var uploadCount = 0
    private var statusCount = 0
    private var releaseCount = 0
    private var appendAllocationBarrier: TwoPartyAllocationBarrier?
    private var failNextUploadBeforePersist = false
    private var failNextUploadAfterPersist = false
    private var failNextRelease = false
    private var corruptNextDownload = false
    private var leaseExpiryOffset: TimeInterval = 900

    func setAppendAllocationBarrier(_ barrier: TwoPartyAllocationBarrier?) {
        appendAllocationBarrier = barrier
    }

    func failNextUploadBeforePersistOnce() {
        failNextUploadBeforePersist = true
    }

    func failNextUploadAfterPersistOnce() {
        failNextUploadAfterPersist = true
    }

    func failNextReleaseOnce() {
        failNextRelease = true
    }

    func corruptNextDownloadOnce() {
        corruptNextDownload = true
    }

    func setLeaseExpiryOffset(_ value: TimeInterval) {
        leaseExpiryOffset = value
    }

    func currentRevisionIDValue() -> String? { currentRevisionID }
    func uploadCountValue() -> Int { uploadCount }
    func statusCountValue() -> Int { statusCount }
    func releaseCountValue() -> Int { releaseCount }

    func recoverableArchive(revisionID: String) -> (archiveSHA256: String, archiveByteCount: UInt64, archive: Data)? {
        guard let upload = archiveByRevision[revisionID], let archive = upload.archive else { return nil }
        return (upload.archiveSHA256, upload.archiveByteCount, archive)
    }

    func allocateMigration(_ request: ProfessionalProjectSyncMigrationRequest) async throws -> ProfessionalProjectSyncUploadAllocation {
        try makeAllocation(
            idempotencyKey: request.idempotencyKey,
            projectID: Self.projectID,
            candidateRevisionID: nextRevisionIdentifier(),
            expectedHostedHeadRevisionID: nil,
            workingSetManifestSHA256: request.workingSetManifestSHA256,
            archiveSHA256: request.archiveSHA256,
            archiveByteCount: request.archiveByteCount,
            isRaw: false
        )
    }

    func allocateRevision(_ request: ProfessionalProjectSyncRevisionRequest) async throws -> ProfessionalProjectSyncUploadAllocation {
        guard request.projectID == Self.projectID,
              request.expectedHeadRevisionID != request.proposedRevisionID,
              request.expectedHostedHeadRevisionID == currentRevisionID
        else { throw ProfessionalProjectSyncError.invalidResponse }
        if let appendAllocationBarrier {
            try await appendAllocationBarrier.arrive(
                participant: request.proposedRevisionID
            )
        }
        return try makeAllocation(
            idempotencyKey: request.idempotencyKey,
            projectID: request.projectID,
            candidateRevisionID: nextRevisionIdentifier(),
            expectedHostedHeadRevisionID: request.expectedHostedHeadRevisionID,
            workingSetManifestSHA256: request.workingSetManifestSHA256,
            archiveSHA256: request.archiveSHA256,
            archiveByteCount: request.archiveByteCount,
            isRaw: false
        )
    }

    func upload(archiveURL: URL, allocation: ProfessionalProjectSyncUploadAllocation) async throws {
        uploadCount += 1
        if failNextUploadBeforePersist {
            failNextUploadBeforePersist = false
            throw DeterministicHostedSyncError.transientNetworkFailure
        }
        guard var upload = uploads[allocation.uploadID] else {
            throw ProfessionalProjectSyncError.invalidResponse
        }
        upload.archive = try Data(contentsOf: archiveURL)
        uploads[allocation.uploadID] = upload
        if failNextUploadAfterPersist {
            failNextUploadAfterPersist = false
            throw ProfessionalProjectSyncError.signedUploadPreconditionFailed
        }
    }

    func complete(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus {
        guard var upload = uploads[uploadID] else { throw ProfessionalProjectSyncError.invalidResponse }
        guard upload.archive != nil else { throw ProfessionalProjectSyncError.invalidResponse }
        upload.completed = true
        uploads[uploadID] = upload
        return status(for: upload, status: .validationPending)
    }

    func uploadStatus(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus {
        statusCount += 1
        guard var upload = uploads[uploadID] else { throw ProfessionalProjectSyncError.invalidResponse }
        guard upload.archive != nil else { return status(for: upload, status: .allocated) }
        guard upload.completed else { return status(for: upload, status: .allocated) }
        if upload.terminalStatus == nil {
            if upload.isRaw {
                upload.terminalStatus = .attached
            } else if let expected = upload.expectedHostedHeadRevisionID,
                      expected != currentRevisionID {
                upload.terminalStatus = .stale
            } else {
                upload.terminalStatus = .canonical
                currentRevisionID = upload.candidateRevisionID
            }
            if !upload.isRaw {
                archiveByRevision[upload.candidateRevisionID] = upload
            }
            uploads[uploadID] = upload
        }
        guard let terminal = upload.terminalStatus else {
            throw ProfessionalProjectSyncError.invalidResponse
        }
        return status(for: upload, status: terminal)
    }

    func allocateRecovery(projectID: String, revisionID: String?) async throws -> ProfessionalProjectSyncRecoveryDownload {
        guard projectID == Self.projectID,
              let requestedRevisionID = revisionID ?? currentRevisionID,
              let upload = archiveByRevision[requestedRevisionID],
              upload.archive != nil
        else { throw ProfessionalProjectSyncError.invalidResponse }
        return .init(
            recovery: .init(
                projectID: Self.projectID,
                revisionID: requestedRevisionID,
                branchState: requestedRevisionID == currentRevisionID ? .canonical : .stale,
                workingSetManifestSHA256: upload.workingSetManifestSHA256,
                archiveSHA256: upload.archiveSHA256,
                archiveByteCount: upload.archiveByteCount
            ),
            transientDownloadURL: URL(string: "https://objects.example.test/recovery/\(requestedRevisionID)")!
        )
    }

    func download(_ recovery: ProfessionalProjectSyncRecoveryDownload, to destinationURL: URL) async throws {
        guard let upload = archiveByRevision[recovery.recovery.revisionID],
              let archive = upload.archive
        else { throw ProfessionalProjectSyncError.invalidResponse }
        if corruptNextDownload {
            corruptNextDownload = false
            try Data("corrupt recovery payload".utf8).write(to: destinationURL, options: .withoutOverwriting)
        } else {
            try archive.write(to: destinationURL, options: .withoutOverwriting)
        }
    }

    func acquireLease(_ request: ProfessionalProjectSyncLeaseRequest) async throws -> ProfessionalProjectSyncLease {
        .init(status: "acquired", expiresAt: Date().addingTimeInterval(leaseExpiryOffset), plaintextToken: nil)
    }

    func renewLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease {
        .init(status: "renewed", expiresAt: Date().addingTimeInterval(leaseExpiryOffset), plaintextToken: nil)
    }

    func releaseLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease {
        releaseCount += 1
        if failNextRelease {
            failNextRelease = false
            throw DeterministicHostedSyncError.transientNetworkFailure
        }
        return .init(status: "released", expiresAt: nil, plaintextToken: nil)
    }

    func configureRawArchive(projectID: String, reviewSHA256: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncRawConfiguration {
        .init(projectID: projectID, rawArchiveEnabled: true, reviewedAt: Date())
    }

    func allocateRawArchive(_ request: ProfessionalProjectSyncRawArchiveRequest) async throws -> ProfessionalProjectSyncUploadAllocation {
        try makeAllocation(
            idempotencyKey: request.idempotencyKey,
            projectID: request.projectID,
            candidateRevisionID: request.revisionID,
            expectedHostedHeadRevisionID: nil,
            workingSetManifestSHA256: request.rawManifestSHA256,
            archiveSHA256: request.archiveSHA256,
            archiveByteCount: request.archiveByteCount,
            isRaw: true
        )
    }

    private func makeAllocation(
        idempotencyKey: String,
        projectID: String,
        candidateRevisionID: String,
        expectedHostedHeadRevisionID: String?,
        workingSetManifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64,
        isRaw: Bool
    ) throws -> ProfessionalProjectSyncUploadAllocation {
        if let existingID = allocationByIdempotency[idempotencyKey],
           let existing = uploads[existingID] {
            return allocation(for: existing)
        }
        let uploadID = String(format: "upl_%016d", nextUploadNumber)
        nextUploadNumber += 1
        let upload = Upload(
            projectID: projectID,
            uploadID: uploadID,
            candidateRevisionID: candidateRevisionID,
            expectedHostedHeadRevisionID: expectedHostedHeadRevisionID,
            workingSetManifestSHA256: workingSetManifestSHA256,
            archiveSHA256: archiveSHA256,
            archiveByteCount: archiveByteCount,
            isRaw: isRaw,
            archive: nil,
            completed: false,
            terminalStatus: nil
        )
        uploads[uploadID] = upload
        allocationByIdempotency[idempotencyKey] = uploadID
        return allocation(for: upload)
    }

    private func allocation(for upload: Upload) -> ProfessionalProjectSyncUploadAllocation {
        .init(
            status: upload.terminalStatus ?? (upload.completed ? .validationPending : .allocated),
            projectID: upload.projectID,
            uploadID: upload.uploadID,
            candidateRevisionID: upload.candidateRevisionID,
            currentHostedHeadRevisionID: currentRevisionID,
            archiveSHA256: upload.archiveSHA256,
            archiveByteCount: upload.archiveByteCount,
            allocationExpiresAt: Date().addingTimeInterval(300),
            transientUploadURL: URL(string: "https://objects.example.test/upload/\(upload.uploadID)")!,
            transientUploadHeaders: ["content-type": "application/zip"]
        )
    }

    private func status(
        for upload: Upload,
        status: ProfessionalProjectSyncStatus
    ) -> ProfessionalProjectSyncUploadStatus {
        .init(
            status: status,
            projectID: upload.projectID,
            uploadID: upload.uploadID,
            candidateRevisionID: upload.candidateRevisionID,
            currentHostedHeadRevisionID: currentRevisionID,
            archiveSHA256: upload.archiveSHA256,
            archiveByteCount: upload.archiveByteCount,
            allocationExpiresAt: Date().addingTimeInterval(300)
        )
    }

    private func nextRevisionIdentifier() -> String {
        defer { nextRevisionNumber += 1 }
        return String(format: "rev_%016d", nextRevisionNumber)
    }
}

private func freshAllocationExpiration() -> String {
    ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
}

@MainActor
private func captureProfessionalSyncOutcome(
    client: String,
    operation: @escaping @MainActor () async throws -> ProfessionalProjectSyncPresentationState
) async -> CapturedProfessionalSyncOutcome {
    do {
        return .state(try await operation())
    } catch {
        return .failure(client: client, description: String(reflecting: error))
    }
}

private func XCTAssertProfessionalSyncThrows(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        // The caller supplies the focused fail-closed path.
    }
}

@MainActor
private func awaitGuestCapturePhase(
    _ coordinator: RoomCaptureCoordinator,
    _ expected: RoomCapturePhase
) async throws {
    for _ in 0..<250 {
        if coordinator.state.phase == expected { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw GuestSyncRouteError.captureDidNotReachPhase(
        expected: expected,
        actual: coordinator.state.phase
    )
}

private enum GuestSyncRouteError: Error {
    case captureDidNotReachPhase(expected: RoomCapturePhase, actual: RoomCapturePhase)
    case stageFailed(String, String)
}

@MainActor
private func guestSyncStage<T>(
    _ name: String,
    operation: @MainActor () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch {
        throw GuestSyncRouteError.stageFailed(name, String(describing: error))
    }
}

@MainActor
private func resetGuestOfflineRoots(arguments: [String]) {
    let fileManager = FileManager.default
    _ = RoomProjectRootResolver.resolve(arguments: arguments, fileManager: fileManager)
    _ = RoomCaptureScratchRootResolver.resolve(arguments: arguments, fileManager: fileManager)
}
