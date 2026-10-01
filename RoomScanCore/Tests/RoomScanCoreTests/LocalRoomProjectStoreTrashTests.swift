import Foundation
import XCTest
@testable import RoomScanCore

final class LocalRoomProjectStoreTrashTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_014_400)

    func testOlderMetadataAndSummaryDecodeMissingNullAndISO8601TrashDates() throws {
        let original = draft().metadata
        let encoded = try RoomJSONCoding.makeEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["trashedAt"], "Nil trash state must preserve historical metadata bytes.")
        for value in [nil, NSNull(), "2027-01-15T12:00:00Z"] as [Any?] {
            json["trashedAt"] = value
            let decoded = try RoomJSONCoding.makeDecoder().decode(
                RoomMetadata.self, from: JSONSerialization.data(withJSONObject: json)
            )
            XCTAssertEqual(decoded.trashedAt, value is String ? date : nil)
            let summary = summary(id: "project-001", trashedAt: decoded.trashedAt)
            XCTAssertEqual(summary.isTrashed, value is String)
            let roundTrip = try RoomJSONCoding.makeDecoder().decode(
                RoomMetadata.self, from: RoomJSONCoding.makeEncoder().encode(decoded)
            )
            XCTAssertEqual(roundTrip, decoded)
        }
        var summaryJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: RoomJSONCoding.makeEncoder().encode(summary(id: "project-001"))
        ) as? [String: Any])
        summaryJSON.removeValue(forKey: "trashedAt")
        let legacySummary = try RoomJSONCoding.makeDecoder().decode(
            RoomProjectSummary.self, from: JSONSerialization.data(withJSONObject: summaryJSON)
        )
        XCTAssertFalse(legacySummary.isTrashed)
        evidence("VAL-TRASH-001", "missing/null/date metadata and legacy summary round-trip")
    }

    func testMoveToTrashUsesClockAndChangesOnlyMetadataTrashDate() async throws {
        let context = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        try await context.store.archive(projectID: "project-001")
        let before = try await context.store.load(projectID: "project-001")
        let beforeBytes = try digests(context.root)
        context.clock.set(date.addingTimeInterval(600))
        try await context.store.moveToTrash(projectID: "project-001")
        let after = try await context.store.load(projectID: "project-001")
        XCTAssertEqual(after.metadata.trashedAt, context.clock.now())
        XCTAssertEqual(after.metadata.lastRevisedDate, before.metadata.lastRevisedDate)
        XCTAssertEqual(after.metadata.archived, before.metadata.archived)
        XCTAssertEqual(after.manifest, before.manifest)
        XCTAssertEqual(after.revisions, before.revisions)
        XCTAssertEqual(try digests(context.root).filter { !$0.key.hasSuffix("metadata.json") },
                       beforeBytes.filter { !$0.key.hasSuffix("metadata.json") })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("project-001/.pending-revision.json").path
        ))
        let trashedBytes = try digests(context.root)
        await assertError(.projectTrashed("project-001")) {
            try await context.store.moveToTrash(projectID: "project-001")
        }
        XCTAssertEqual(try digests(context.root), trashedBytes)
        evidence("VAL-TRASH-002", "clock stamped; head, revision bytes, archive and lastRevisedDate unchanged")
    }

    func testRestoreKeepsOriginalSortPositionHeadAndDatesAndRejectsActiveRestore() async throws {
        let context = try await makeContext(projectIDs: ["project-a", "project-b", "project-c"])
        defer { try? FileManager.default.removeItem(at: context.root) }
        context.clock.set(date.addingTimeInterval(100))
        _ = try await context.store.saveDraft(draft(), decision: .save)
        context.clock.set(date.addingTimeInterval(200))
        _ = try await context.store.saveDraft(draft(), decision: .save)
        let before = try await context.store.listProjectListing()
        XCTAssertEqual(before.summaries.map(\.projectID), ["project-c", "project-b", "project-a"])
        let packageBefore = try await context.store.load(projectID: "project-b")
        try await context.store.moveToTrash(projectID: "project-b")
        let hidden = try await context.store.listProjectListing()
        XCTAssertEqual(hidden.summaries.map(\.projectID), ["project-c", "project-a"])
        context.clock.set(date.addingTimeInterval(10_000))
        try await context.store.restoreFromTrash(projectID: "project-b")
        let after = try await context.store.listProjectListing()
        XCTAssertEqual(after, before)
        let packageAfter = try await context.store.load(projectID: "project-b")
        XCTAssertEqual(packageAfter, packageBefore)
        let restoredBytes = try digests(context.root)
        await assertError(.projectNotTrashed("project-b")) {
            try await context.store.restoreFromTrash(projectID: "project-b")
        }
        XCTAssertEqual(try digests(context.root), restoredBytes)
        evidence("VAL-TRASH-003", "restore returned original order, dates and head; active restore rejected")
    }

    func testAllListingFilterCombinationsPreserveArchivedTrashState() async throws {
        let context = try await makeContext(projectIDs: ["active", "archived", "trash", "both"])
        defer { try? FileManager.default.removeItem(at: context.root) }
        for _ in 0..<3 { _ = try await context.store.saveDraft(draft(), decision: .save) }
        try await context.store.archive(projectID: "archived")
        try await context.store.archive(projectID: "both")
        try await context.store.moveToTrash(projectID: "trash")
        try await context.store.moveToTrash(projectID: "both")
        for archived in [false, true] {
            for trashed in [false, true] {
                let listing = try await context.store.listProjectListing(
                    includeArchived: archived, includeTrashed: trashed
                )
                var expected: Set<String> = ["active"]
                if archived { expected.insert("archived") }
                if trashed { expected.insert("trash") }
                if archived && trashed { expected.insert("both") }
                XCTAssertEqual(Set(listing.summaries.map(\.projectID)), expected)
                for item in listing.summaries {
                    XCTAssertEqual(item.isTrashed, ["trash", "both"].contains(item.projectID))
                    XCTAssertEqual(item.trashedAt, item.isTrashed ? date : nil)
                    XCTAssertEqual(item.archived, ["archived", "both"].contains(item.projectID))
                }
            }
        }
        let defaults = try await context.store.listProjectListing(includeArchived: true)
        XCTAssertEqual(Set(defaults.summaries.map(\.projectID)), ["active", "archived"])
        let summaries = try await context.store.listSummaries(includeArchived: true)
        XCTAssertEqual(summaries, defaults.summaries)
        evidence("VAL-TRASH-004", "all four archive/trash filters and default-off listing verified")
    }

    // Each public mutation/outbound entry point has its own rejection and
    // restored-success control, including the two saveDraft overloads.
    func testSaveDraftDecisionRejectsTrash() async throws { try await check(.saveDecision) }
    func testSaveDraftDispositionRejectsTrash() async throws { try await check(.saveDisposition) }
    func testInitialCaptureRejectsTrash() async throws { try await check(.initialCapture) }
    func testAppendRevisionRejectsTrash() async throws { try await check(.append) }
    func testAppendEditRevisionRejectsTrash() async throws { try await check(.appendEdit) }
    func testCommitEditRevisionRejectsTrash() async throws { try await check(.commitEdit) }
    func testFixtureRescanRegistrationRejectsTrash() async throws { try await check(.rescan) }
    func testRestoreAsNewRevisionRejectsTrash() async throws { try await check(.revisionRestore) }
    func testMetadataRenameRejectsTrash() async throws { try await check(.metadata) }
    func testDuplicateRejectsTrash() async throws { try await check(.duplicate) }
    func testArchiveRejectsTrash() async throws { try await check(.archive) }
    func testUnarchiveRejectsTrash() async throws { try await check(.unarchive) }
    func testHeadExportRejectsTrash() async throws { try await check(.export) }
    func testAIPackageInputBindingRejectsTrash() async throws { try await check(.redesignBinding) }
    func testBackupArchiveInputRejectsTrash() async throws { try await check(.backup) }
    func testProfessionalWorkingCopyRejectsTrash() async throws { try await check(.professionalCopy) }
    func testPublishHeroCacheRejectsTrash() async throws { try await check(.publishHero) }
    func testInvalidateHeroCacheRejectsTrash() async throws { try await check(.invalidateHero) }

    func testWorkingCopyRechecksTrashAtFinalPromotionAndCleansStage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrashPromotion-\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let injector = TrashAtWorkingCopyPromotion(root: root, date: date)
        let store = LocalRoomProjectStore(
            rootURL: root, clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(projectIDs: ["project-001"], revisionIDs: ["revision-001"]),
            faultInjector: injector
        )
        _ = try await store.saveDraft(draft(), decision: .save)
        let before = try digests(root).filter { !$0.key.hasSuffix("metadata.json") }
        await assertError(.projectTrashed("project-001")) {
            _ = try await store.materializeProfessionalWorkingCopy(
                projectID: "project-001", expectedHeadRevisionID: "revision-001",
                into: external.appendingPathComponent("copy")
            )
        }
        let package = try await store.load(projectID: "project-001")
        XCTAssertEqual(package.metadata.trashedAt, date, "The injected concurrent trash actually occurred.")
        XCTAssertEqual(try digests(root).filter { !$0.key.hasSuffix("metadata.json") }, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        evidence("VAL-TRASH-005", "trash at final working-copy promotion rejects handoff and cleans owned stage")
    }

    func testInitialCaptureRechecksTrashAfterSuspendingIDGeneration() async throws {
        let context = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let original = try await context.store.load(projectID: "project-001")
        let generator = TrashDuringIDGenerator(store: context.store)
        let suspendedStore = LocalRoomProjectStore(rootURL: context.root, idGenerator: generator)
        await assertError(.projectTrashed("project-001")) {
            _ = try await suspendedStore.saveDraft(
                RoomDraft(metadata: original.metadata, revision: original.revisions[0].payload), decision: .save
            )
        }
        let trashed = try await context.store.load(projectID: "project-001")
        XCTAssertNotNil(trashed.metadata.trashedAt)
        let listing = try await context.store.listProjectListing(includeArchived: true, includeTrashed: true)
        XCTAssertEqual(listing.summaries.map(\.projectID), ["project-001"])
        evidence("VAL-TRASH-005", "initial capture source rechecked after ID-generator suspension")
    }

    func testPreparedRecoveryPromotionRejectsTrashedDestinationThenSucceedsAfterRestore() async throws {
        let context = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let workspace = context.root.appendingPathComponent("backup")
        // External workspaces must not be inside the projects root.
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let materialized = try await context.store.materializeBackupSnapshot(
            projectID: "project-001", expectedHeadRevisionID: "revision-001",
            into: external.appendingPathComponent(workspace.lastPathComponent)
        )
        let archive = try await RoomProjectBackupArchive.build(
            materialization: materialized, archiveURL: external.appendingPathComponent("backup.zip")
        )
        let prepared = try await context.store.prepareRecovery(
            archiveURL: archive.archiveURL, expectedCloudDescriptor: archive.descriptor,
            into: external.appendingPathComponent("recovery")
        )
        try await context.store.moveToTrash(projectID: "project-001")
        let before = try digests(context.root)
        await assertError(.projectTrashed("project-001")) {
            _ = try await context.store.commitPreparedRecovery(prepared, conflictPolicy: .failIfDivergent)
        }
        await assertError(.projectTrashed("project-001")) {
            _ = try await context.store.commitPreparedRecovery(prepared, conflictPolicy: .recoverAsCopy)
        }
        await assertError(.projectTrashed("project-001")) {
            _ = try await context.store.commitPreparedRecovery(
                prepared, conflictPolicy: .recoverAsCopy, recoveredCopyProjectID: "recovery-copy"
            )
        }
        XCTAssertEqual(try digests(context.root), before)
        try await context.store.restoreFromTrash(projectID: "project-001")
        let result = try await context.store.commitPreparedRecovery(prepared, conflictPolicy: .failIfDivergent)
        XCTAssertEqual(result, .noOp)
        evidence("VAL-TRASH-005", "staged backup promotion fails typed, preserves bytes and succeeds after restore")
    }

    func testPreparedRecoveryRejectsTrashedExplicitCopyDestination() async throws {
        let context = try await makeContext(projectIDs: ["project-001", "trashed-copy"])
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: context.root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        _ = try await context.store.saveDraft(draft(), decision: .save)
        let materialized = try await context.store.materializeBackupSnapshot(
            projectID: "project-001", expectedHeadRevisionID: "revision-001", into: external.appendingPathComponent("backup")
        )
        let archive = try await RoomProjectBackupArchive.build(
            materialization: materialized, archiveURL: external.appendingPathComponent("backup.zip")
        )
        let prepared = try await context.store.prepareRecovery(
            archiveURL: archive.archiveURL, expectedCloudDescriptor: archive.descriptor, into: external.appendingPathComponent("recovery")
        )
        try await context.store.moveToTrash(projectID: "trashed-copy")
        let before = try digests(context.root)
        await assertError(.projectTrashed("trashed-copy")) {
            _ = try await context.store.commitPreparedRecovery(
                prepared, conflictPolicy: .recoverAsCopy, recoveredCopyProjectID: "trashed-copy"
            )
        }
        XCTAssertEqual(try digests(context.root), before)
        try await context.store.discardPreparedRecovery(prepared)
        evidence("VAL-TRASH-005", "explicit recovered-copy identity cannot target an existing trashed package")
    }

    func testMetadataEditCannotBypassTrashLifecycle() async throws {
        let context = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        var metadata = try await context.store.load(projectID: "project-001").metadata
        metadata.trashedAt = date
        await assertError(.invalidPackage("Trash state can only change through the trash lifecycle.")) {
            _ = try await context.store.updateMetadata(projectID: "project-001", metadata: metadata)
        }
        let package = try await context.store.load(projectID: "project-001")
        XCTAssertNil(package.metadata.trashedAt)
    }

    func testPermanentDeleteRemovesActiveAndTrashedPackages() async throws {
        for trash in [false, true] {
            let context = try await makeContext()
            defer { try? FileManager.default.removeItem(at: context.root) }
            if trash { try await context.store.moveToTrash(projectID: "project-001") }
            try await context.store.permanentlyDelete(projectID: "project-001")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: context.root.appendingPathComponent("project-001").path
            ))
            await assertError(.projectNotFound("project-001")) {
                _ = try await context.store.load(projectID: "project-001")
            }
            let listing = try await context.store.listProjectListing(includeArchived: true, includeTrashed: true)
            XCTAssertTrue(listing.summaries.isEmpty)
        }
        evidence("VAL-TRASH-006", "active and trashed project directories entirely removed")
    }

    func testPermanentDeleteRejectsUnsafeIDsAndSymlinkedPackageOrRoot() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("projects")
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("retained".utf8).write(to: outside.appendingPathComponent("canary"))
        let before = try digests(outside)
        let store = LocalRoomProjectStore(rootURL: root)
        for identifier in ["../outside", "", "/outside", "x/y", ".."] {
            await assertError(.invalidIdentifier(identifier)) {
                try await store.permanentlyDelete(projectID: identifier)
            }
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside
        )
        do {
            try await store.permanentlyDelete(projectID: "linked")
            XCTFail("Symlinked package must be rejected")
        } catch {
            guard case .symbolicLinkDetected = error as? RoomProjectStoreError else {
                return XCTFail("Expected typed symlink error, got \(error)")
            }
        }
        let linkedRoot = temporary.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        do {
            try await LocalRoomProjectStore(rootURL: linkedRoot).permanentlyDelete(projectID: "linked")
            XCTFail("Symlinked root must be rejected")
        } catch {
            guard case .symbolicLinkDetected = error as? RoomProjectStoreError else {
                return XCTFail("Expected typed root symlink error, got \(error)")
            }
        }
        XCTAssertEqual(try digests(outside), before)
        evidence("VAL-TRASH-006", "unsafe identifiers, linked packages and roots rejected; external canary unchanged")
    }

    func testRetentionPolicyInclusiveBoundaryNilAndDeterministicOrdering() {
        let policy = RoomTrashRetentionPolicy()
        XCTAssertEqual(RoomTrashRetentionPolicy.retention, 2_592_000)
        XCTAssertEqual(policy.purgeDate(trashedAt: date), date.addingTimeInterval(2_592_000))
        let trashed = summary(id: "project-b", trashedAt: date)
        XCTAssertEqual(policy.expiredProjectIDs(summaries: [trashed], now: date.addingTimeInterval(2_588_400)), [])
        XCTAssertEqual(policy.expiredProjectIDs(summaries: [trashed], now: date.addingTimeInterval(2_592_000)), ["project-b"])
        XCTAssertEqual(policy.expiredProjectIDs(summaries: [trashed], now: date.addingTimeInterval(2_592_001)), ["project-b"])
        XCTAssertEqual(policy.expiredProjectIDs(
            summaries: [trashed, summary(id: "active"), summary(id: "project-a", trashedAt: date),
                        summary(id: "recent", trashedAt: date.addingTimeInterval(1))],
            now: date.addingTimeInterval(2_592_000)
        ), ["project-a", "project-b"])
        evidence("VAL-TRASH-007", "29d23h retained; exactly 30d and +1s expired; active excluded; IDs sorted")
    }

    private enum Operation: String {
        case saveDecision, saveDisposition, initialCapture, append, appendEdit, commitEdit, rescan
        case revisionRestore, metadata, duplicate, archive, unarchive, export, redesignBinding
        case backup, professionalCopy, publishHero, invalidateHero
    }

    private func check(_ operation: Operation) async throws {
        let context = try await makeContext(projectIDs: ["project-001", "project-copy"])
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: context.root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let package = try await context.store.load(projectID: "project-001")
        try await context.store.moveToTrash(projectID: "project-001")
        let before = try digests(context.root)
        await assertError(.projectTrashed("project-001")) {
            try await self.perform(operation, context: context, package: package, external: external)
        }
        XCTAssertEqual(try digests(context.root), before, operation.rawValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        let read = try await context.store.load(projectID: "project-001")
        XCTAssertNotNil(read.metadata.trashedAt)
        let listing = try await context.store.listProjectListing(includeArchived: true, includeTrashed: true)
        XCTAssertEqual(listing.summaries.count, 1)
        try await context.store.restoreFromTrash(projectID: "project-001")
        try await perform(operation, context: context, package: package, external: external)
        evidence("VAL-TRASH-005", "\(operation.rawValue): typed rejection, identical SHA-256 closure, restored success")
    }

    private func perform(
        _ operation: Operation, context: Context, package: RoomProjectPackage, external: URL
    ) async throws {
        let store = context.store
        let payload = try XCTUnwrap(package.revisions.last).payload
        let draft = RoomDraft(metadata: package.metadata, revision: payload)
        switch operation {
        case .saveDecision: _ = try await store.saveDraft(draft, decision: .save)
        case .saveDisposition: _ = try await store.saveDraft(draft, disposition: .save)
        case .initialCapture:
            _ = try await store.commitInitialCapture(
                RoomInitialCaptureCommit(draft: draft, evidence: nil, assets: []), decision: .save
            )
        case .append:
            _ = try await store.appendRevision(
                projectID: "project-001", revisionID: "revision-new", parentRevisionID: "revision-001",
                reason: .edit, payload: payload, restoredFromRevisionID: nil
            )
        case .appendEdit:
            _ = try await store.appendEditRevision(projectID: "project-001", payload: payload, newRevisionID: "revision-new")
        case .commitEdit:
            _ = try await store.commitEditRevision(
                projectID: "project-001", expectedHeadRevisionID: "revision-001",
                payload: payload, newRevisionID: "revision-new"
            )
        case .rescan:
            let proposal = try RoomRescanEngine.makeFixtureProposal(
                basePayload: payload, expectedHeadRevisionID: "revision-001",
                registrationProof: RoomDeterministicRescanRegistrationProof(
                    fixtureID: RoomDeterministicRescanRegistrationProof.fixtureV1ID,
                    projectID: "project-001", baseRevisionID: "revision-001",
                    coordinateFrameID: RoomDeterministicRescanRegistrationProof.fixtureV1FrameID,
                    proofToken: RoomDeterministicRescanRegistrationProof.fixtureV1ProofToken
                ), candidateSnapshot: payload.semanticSnapshot, matches: []
            )
            _ = try await store.acceptFixtureRescan(
                projectID: "project-001", expectedHeadRevisionID: "revision-001",
                proposal: proposal, newRevisionID: "revision-new"
            )
        case .revisionRestore:
            _ = try await store.restoreAsNewRevision(
                projectID: "project-001", sourceRevisionID: "revision-001", newRevisionID: "revision-new"
            )
        case .metadata:
            var metadata = package.metadata
            metadata.customName = "Renamed"
            _ = try await store.updateMetadata(projectID: "project-001", metadata: metadata)
        case .duplicate: _ = try await store.duplicate(projectID: "project-001")
        case .archive: try await store.archive(projectID: "project-001")
        case .unarchive: try await store.unarchive(projectID: "project-001")
        case .export:
            _ = try await store.materializeHeadForExport(
                projectID: "project-001", expectedHeadRevisionID: "revision-001", into: external.appendingPathComponent("export")
            )
        case .redesignBinding:
            _ = try await store.redesignSourceRevisionBinding(projectID: "project-001", revisionID: "revision-001")
        case .backup:
            _ = try await store.materializeBackupSnapshot(
                projectID: "project-001", expectedHeadRevisionID: "revision-001", into: external.appendingPathComponent("backup")
            )
        case .professionalCopy:
            _ = try await store.materializeProfessionalWorkingCopy(
                projectID: "project-001", expectedHeadRevisionID: "revision-001", into: external.appendingPathComponent("professional")
            )
        case .publishHero:
            try await store.publishHeroCache(
                projectID: "project-001",
                manifest: RoomMeshHeroCacheManifest(
                    heroAlgorithmVersion: 1,
                    photorealManifest: RoomMeshPhotorealCacheManifest(
                        algorithmVersion: 3, sourceMeshSHA256: "test", bundleManifestSHA256: "test",
                        sourceFrames: [], atlasSize: 1, coveredFaceCount: 0, coveredAreaEstimate: 0,
                        colorSpaceTag: "sRGB", settings: RoomMeshPhotorealSettings()
                    ), coloredMeshSHA256: "test", atlasSHA256: nil,
                    pixelWidth: 1, pixelHeight: 1, colorSpaceTag: "sRGB"
                ), imageData: Data("synthetic".utf8)
            )
        case .invalidateHero: try await store.invalidateHeroCache(projectID: "project-001")
        }
    }

    private struct Context {
        let root: URL
        let store: LocalRoomProjectStore
        let clock: TestClock
    }

    private func makeContext(projectIDs: [String] = ["project-001"]) async throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrashTests-\(UUID().uuidString)")
        let clock = TestClock(date: date)
        let store = LocalRoomProjectStore(
            rootURL: root, clock: clock,
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: projectIDs, revisionIDs: ["revision-001", "revision-002", "revision-003", "revision-004"]
            )
        )
        _ = try await store.saveDraft(draft(), decision: .save)
        return Context(root: root, store: store, clock: clock)
    }

    private func draft() -> RoomDraft {
        RoomDraft(
            metadata: RoomMetadata(
                projectID: "draft-project", customName: "Synthetic room", captureDate: date, lastRevisedDate: date,
                manualLocation: "", optionalGPS: nil, notes: "", tags: [], thumbnailRelativePath: nil, archived: false
            ),
            revision: RoomRevisionPayload(
                semanticSnapshot: RoomSemanticSnapshot(
                    projectID: "draft-project", revisionID: "draft-revision", units: "meters",
                    accuracyDisclaimer: "Synthetic estimates", structuralElements: [], objectElements: []
                ), annotations: [], measurements: [], photos: []
            )
        )
    }

    private func summary(id: String, trashedAt: Date? = nil) -> RoomProjectSummary {
        RoomProjectSummary(
            projectID: id, customName: id, captureDate: date, lastRevisedDate: date, manualLocation: "", tags: [],
            thumbnailRelativePath: nil, archived: false, headRevisionID: "revision-001", trashedAt: trashedAt
        )
    }

    private func digests(_ root: URL) throws -> [String: String] {
        let root = root.resolvingSymlinksInPath()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var result: [String: String] = [:]
        while let file = files?.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(root.path.count + 1))] = try RoomSHA256.hexDigest(ofFile: file)
            }
        }
        return result
    }

    private func assertError(_ expected: RoomProjectStoreError, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch { XCTAssertEqual(error as? RoomProjectStoreError, expected) }
    }

    private func evidence(_ id: String, _ text: String) {
        #if canImport(Darwin)
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(id)-core-trash"
        attachment.lifetime = .keepAlways
        add(attachment)
        #else
        print("\(id)-core-trash: \(text)")
        #endif
    }
}

private final class TestClock: RoomProjectClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(date: Date) { self.date = date }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.date = date
    }
}

private struct TrashAtWorkingCopyPromotion: RoomProjectStoreFaultInjecting {
    let root: URL
    let date: Date
    func throwIfNeeded(at point: RoomProjectStoreFaultPoint) throws {
        guard point == .beforeProfessionalWorkingCopyPromotion else { return }
        // Simulates the metadata write of another root-sharing store while
        // this store is outside the root lock doing external validation.
        let metadataURL = root.appendingPathComponent("project-001/metadata.json")
        var metadata = try RoomJSONCoding.makeDecoder().decode(
            RoomMetadata.self, from: Data(contentsOf: metadataURL)
        )
        metadata.trashedAt = date
        try RoomJSONCoding.makeEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }
}

private actor TrashDuringIDGenerator: RoomProjectIDGenerating {
    let store: LocalRoomProjectStore
    init(store: LocalRoomProjectStore) { self.store = store }
    func nextProjectID() async -> String {
        try? await store.moveToTrash(projectID: "project-001")
        return "new-project"
    }
    func nextRevisionID() async -> String { "new-revision" }
}
