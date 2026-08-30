import Foundation
import XCTest
@testable import RoomScanCore

final class RoomProfessionalRecoveryTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)

    func testRecoveredCopyMappingRequiresSafeDistinctProjectIDs() throws {
        XCTAssertNoThrow(try RoomProfessionalRecoveredCopyMapping(
            originalProjectID: "project-001",
            recoveredCopyProjectID: "project-copy"
        ))
        XCTAssertThrowsError(try RoomProfessionalRecoveredCopyMapping(
            originalProjectID: "project-001",
            recoveredCopyProjectID: "project-001"
        ))
        XCTAssertThrowsError(try RoomProfessionalRecoveredCopyMapping(
            originalProjectID: "project 001",
            recoveredCopyProjectID: "project-copy"
        ))
    }

    func testRecoverySourceGateRejectsImplicitAndIDOnlyCopyRebinding() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveredCopyAuthority-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let bindings = try await storeDerivedCopyBindings(in: temporary)
        let original = bindings.original
        let recoveredCopy = bindings.copy
        XCTAssertThrowsError(try RoomProfessionalRecoveryRebinding.targetSourceRevision(
            original: original,
            expected: recoveredCopy,
            mapping: nil
        ))
        let mapping = try RoomProfessionalRecoveredCopyMapping(
            originalProjectID: original.projectID,
            recoveredCopyProjectID: recoveredCopy.projectID
        )
        XCTAssertThrowsError(try RoomProfessionalRecoveryRebinding.targetSourceRevision(
            original: original,
            expected: recoveredCopy,
            mapping: mapping
        ))
        XCTAssertEqual(
            try RoomProfessionalRecoveryRebinding.targetSourceRevision(
                original: original,
                expected: recoveredCopy,
                mapping: bindings.mapping
            ),
            recoveredCopy
        )
    }

    func testStoreDerivedCopyBindingAcceptsActualRewrittenPackageDigestsOnly() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveredCopyDigests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let bindings = try await storeDerivedCopyBindings(in: temporary)
        XCTAssertNotEqual(bindings.original.semanticSHA256, bindings.copy.semanticSHA256)
        XCTAssertNotEqual(
            bindings.original.revisionManifestSHA256,
            bindings.copy.revisionManifestSHA256
        )
        let idOnly = try RoomProfessionalRecoveredCopyMapping(
            originalProjectID: bindings.original.projectID,
            recoveredCopyProjectID: bindings.copy.projectID
        )
        XCTAssertThrowsError(try RoomProfessionalRecoveryRebinding.targetSourceRevision(
            original: bindings.original,
            expected: bindings.copy,
            mapping: idOnly
        ))
        XCTAssertEqual(
            try RoomProfessionalRecoveryRebinding.targetSourceRevision(
                original: bindings.original,
                expected: bindings.copy,
                mapping: bindings.mapping
            ),
            bindings.copy
        )
    }

    func testRedesignCompanionSnapshotRestoresIdempotentlyAndOnlyExplicitCopyMappingRebinds() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ProfessionalRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bindings = try await storeDerivedCopyBindings(in: temporary)
        let sourceBinding = bindings.original
        let copyBinding = bindings.copy
        let sourceStore = LocalRoomRedesignStore(rootURL: temporary.appendingPathComponent("source"))
        let sourceDocument = try extensionDocument(binding: sourceBinding)
        try await sourceStore.save(sourceDocument, expectedSourceRevision: sourceBinding)
        let sourceBytes = try fileSnapshot(at: temporary.appendingPathComponent("source"))
        let optionalSnapshot = try await sourceStore.snapshot(sourceRevision: sourceBinding)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        XCTAssertEqual(snapshot.sourceRevision, sourceBinding)
        XCTAssertEqual(snapshot.documentSHA256, RoomSHA256.hexDigest(of: snapshot.canonicalDocumentData))
        XCTAssertEqual(try snapshot.workingSetCompanions().map(\.path), ["companions/redesign.json"])

        let absent = try await LocalRoomRedesignStore(
            rootURL: temporary.appendingPathComponent("absent")
        ).snapshot(sourceRevision: sourceBinding)
        XCTAssertNil(absent)

        let originalDestination = LocalRoomRedesignStore(rootURL: temporary.appendingPathComponent("original"))
        try await originalDestination.restoreSnapshot(
            snapshot,
            expectedSourceRevision: sourceBinding
        )
        try await originalDestination.restoreSnapshot(
            snapshot,
            expectedSourceRevision: sourceBinding
        )
        let restoredOriginal = try await originalDestination.load(sourceRevision: sourceBinding)
        XCTAssertEqual(restoredOriginal, sourceDocument)

        let conflictingDestination = LocalRoomRedesignStore(rootURL: temporary.appendingPathComponent("conflicting"))
        var conflictingDocument = sourceDocument
        conflictingDocument.redesignIntent?.request = "A conflicting local redesign must remain untouched."
        try await conflictingDestination.save(conflictingDocument, expectedSourceRevision: sourceBinding)
        await assertThrowsAsync {
            try await conflictingDestination.restoreSnapshot(
                snapshot,
                expectedSourceRevision: sourceBinding
            )
        }
        let retainedConflictingDocument = try await conflictingDestination.load(
            sourceRevision: sourceBinding
        )
        XCTAssertEqual(retainedConflictingDocument, conflictingDocument)

        let forbiddenCopyRoot = temporary.appendingPathComponent("forbidden-copy")
        await assertThrowsAsync {
            try await LocalRoomRedesignStore(rootURL: forbiddenCopyRoot).restoreSnapshot(
                snapshot,
                expectedSourceRevision: copyBinding
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbiddenCopyRoot.path))

        let copiedDestination = LocalRoomRedesignStore(rootURL: temporary.appendingPathComponent("copy"))
        try await copiedDestination.restoreSnapshot(
            snapshot,
            expectedSourceRevision: copyBinding,
            recoveredCopyMapping: bindings.mapping
        )
        let optionalCopied = try await copiedDestination.load(sourceRevision: copyBinding)
        let copied = try XCTUnwrap(optionalCopied)
        XCTAssertEqual(copied.sourceRevision, copyBinding)
        XCTAssertEqual(try fileSnapshot(at: temporary.appendingPathComponent("source")), sourceBytes)
    }

    func testConceptSnapshotsRestoreExactClosureAndOnlyExplicitCopyRebinds() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ProfessionalConceptRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let bindings = try await storeDerivedCopyBindings(in: temporary)
        let sourceBinding = bindings.original
        let copyBinding = bindings.copy
        let sourcePackageRoot = temporary.appendingPathComponent("source-package", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePackageRoot, withIntermediateDirectories: false)
        let sourceConceptRoot = temporary.appendingPathComponent("source-concepts", isDirectory: true)
        let sourceContext = conceptContext(binding: sourceBinding)
        let sourceStore = LocalRoomConceptStore(
            rootURL: sourceConceptRoot,
            sourcePackageRootURL: sourcePackageRoot
        )
        _ = try await sourceStore.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-002",
                attachmentID: "attachment-002",
                sourceRevision: sourceBinding,
                importedOffset: 200
            ),
            context: sourceContext
        )
        _ = try await sourceStore.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-001",
                attachmentID: "attachment-001",
                sourceRevision: sourceBinding,
                importedOffset: 100
            ),
            context: sourceContext
        )
        let sourceBytes = try fileSnapshot(at: sourceConceptRoot)
        let snapshot = try await sourceStore.snapshot(context: sourceContext)
        XCTAssertEqual(snapshot.sourceRevision, sourceBinding)
        XCTAssertEqual(snapshot.conceptSets.map(\.conceptSetID), ["concept-set-001", "concept-set-002"])
        XCTAssertEqual(
            try snapshot.workingSetCompanions().map(\.path),
            [
                "companions/concept-sets/concept-set-001/attachments/attachment-001.png",
                "companions/concept-sets/concept-set-001/manifest.json",
                "companions/concept-sets/concept-set-002/attachments/attachment-002.png",
                "companions/concept-sets/concept-set-002/manifest.json",
            ]
        )

        let originalPackageRoot = temporary.appendingPathComponent("original-package", isDirectory: true)
        try FileManager.default.createDirectory(at: originalPackageRoot, withIntermediateDirectories: false)
        let originalConceptRoot = temporary.appendingPathComponent("original-concepts", isDirectory: true)
        let originalDestination = LocalRoomConceptStore(
            rootURL: originalConceptRoot,
            sourcePackageRootURL: originalPackageRoot
        )
        try await originalDestination.restoreSnapshot(snapshot, context: sourceContext)
        try await originalDestination.restoreSnapshot(snapshot, context: sourceContext)
        let restoredConceptSnapshot = try await originalDestination.snapshot(context: sourceContext)
        XCTAssertEqual(restoredConceptSnapshot, snapshot)

        let copyPackageRoot = temporary.appendingPathComponent("copy-package", isDirectory: true)
        try FileManager.default.createDirectory(at: copyPackageRoot, withIntermediateDirectories: false)
        let copyConceptRoot = temporary.appendingPathComponent("copy-concepts", isDirectory: true)
        let copyContext = conceptContext(binding: copyBinding)
        let copiedDestination = LocalRoomConceptStore(
            rootURL: copyConceptRoot,
            sourcePackageRootURL: copyPackageRoot
        )
        await assertThrowsAsync {
            try await copiedDestination.restoreSnapshot(snapshot, context: copyContext)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyConceptRoot.path))

        try await copiedDestination.restoreSnapshot(
            snapshot,
            context: copyContext,
            recoveredCopyMapping: bindings.mapping
        )
        let copiedSnapshot = try await copiedDestination.snapshot(context: copyContext)
        XCTAssertEqual(copiedSnapshot.sourceRevision, copyBinding)
        XCTAssertEqual(copiedSnapshot.conceptSets.map(\.sourceRevision), [copyBinding, copyBinding])
        XCTAssertEqual(
            copiedSnapshot.conceptSets.flatMap(\.attachments).map(\.data),
            snapshot.conceptSets.flatMap(\.attachments).map(\.data)
        )
        XCTAssertEqual(try fileSnapshot(at: sourceConceptRoot), sourceBytes)
    }

    func testConceptRestoreRejectsCorruptSnapshotsBeforeAnyPromotion() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ProfessionalConceptRecoveryCorrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let sourceBinding = sourceRevision(projectID: "project-001")
        let sourcePackageRoot = temporary.appendingPathComponent("source-package", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePackageRoot, withIntermediateDirectories: false)
        let sourceConceptRoot = temporary.appendingPathComponent("source-concepts", isDirectory: true)
        let context = conceptContext(binding: sourceBinding)
        let sourceStore = LocalRoomConceptStore(
            rootURL: sourceConceptRoot,
            sourcePackageRootURL: sourcePackageRoot
        )
        _ = try await sourceStore.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-001",
                attachmentID: "attachment-001",
                sourceRevision: sourceBinding,
                importedOffset: 100
            ),
            context: context
        )
        _ = try await sourceStore.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-002",
                attachmentID: "attachment-002",
                sourceRevision: sourceBinding,
                importedOffset: 200
            ),
            context: context
        )
        let snapshot = try await sourceStore.snapshot(context: context)

        var duplicateSet = snapshot
        duplicateSet.conceptSets.append(try XCTUnwrap(snapshot.conceptSets.first))
        var missingAttachment = snapshot
        missingAttachment.conceptSets[0].attachments.removeAll()
        var extraAttachment = snapshot
        extraAttachment.conceptSets[0].attachments.append(try XCTUnwrap(snapshot.conceptSets[0].attachments.first))
        var digestMismatch = snapshot
        digestMismatch.conceptSets[0].attachments[0].sha256 = String(repeating: "f", count: 64)
        var sourceMismatch = snapshot
        sourceMismatch.conceptSets[0].sourceRevision = sourceRevision(projectID: "project-copy")

        for (index, corrupt) in [duplicateSet, missingAttachment, extraAttachment, digestMismatch, sourceMismatch].enumerated() {
            let destinationPackageRoot = temporary.appendingPathComponent("corrupt-package-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationPackageRoot, withIntermediateDirectories: false)
            let destinationRoot = temporary.appendingPathComponent("corrupt-concepts-\(index)", isDirectory: true)
            let destination = LocalRoomConceptStore(
                rootURL: destinationRoot,
                sourcePackageRootURL: destinationPackageRoot
            )
            await assertThrowsAsync {
                try await destination.restoreSnapshot(corrupt, context: context)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.path))
        }
    }

    func testConceptRecoveryPreservesMixedArchivedAndReviewedStatesWithoutPartialPromotion() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalConceptRecoveryStates-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let binding = sourceRevision(projectID: "project-001")
        let sourcePackageRoot = temporary.appendingPathComponent("source-package", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePackageRoot, withIntermediateDirectories: false)
        let sourceRoot = temporary.appendingPathComponent("source-concepts", isDirectory: true)
        let context = conceptContext(binding: binding)
        let source = LocalRoomConceptStore(
            rootURL: sourceRoot,
            sourcePackageRootURL: sourcePackageRoot
        )

        _ = try await source.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-001",
                attachmentID: "attachment-001",
                sourceRevision: binding,
                importedOffset: 100
            ),
            context: context
        )
        _ = try await source.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-002",
                attachmentID: "attachment-002",
                sourceRevision: binding,
                importedOffset: 200
            ),
            context: context
        )
        var approved = try await source.load(conceptSetID: "concept-set-002", context: context)
        approved.approvalState = .approved
        approved.comments = ["Approved after local review."]
        _ = try await source.updateReview(approved, context: context)

        _ = try await source.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-003",
                attachmentID: "attachment-003",
                sourceRevision: binding,
                importedOffset: 300
            ),
            context: context
        )
        var rejected = try await source.load(conceptSetID: "concept-set-003", context: context)
        rejected.approvalState = .rejected
        rejected.comments = ["Rejected after local review."]
        _ = try await source.updateReview(rejected, context: context)
        _ = try await source.archive(conceptSetID: "concept-set-003", context: context)

        let snapshot = try await source.snapshot(context: context)
        let persistedStates = try snapshot.conceptSets.map { snapshot in
            let concept = try snapshot.validatedConcept()
            return "\(concept.conceptSetID):\(concept.approvalState.rawValue):\(concept.archiveState.rawValue)"
        }
        XCTAssertEqual(
            persistedStates,
            [
                "concept-set-001:pending:active",
                "concept-set-002:approved:active",
                "concept-set-003:rejected:archived",
            ]
        )

        let destinationPackageRoot = temporary.appendingPathComponent("destination-package", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationPackageRoot, withIntermediateDirectories: false)
        let destinationRoot = temporary.appendingPathComponent("destination-concepts", isDirectory: true)
        let destination = LocalRoomConceptStore(
            rootURL: destinationRoot,
            sourcePackageRootURL: destinationPackageRoot
        )
        var restoreError: Error?
        do {
            try await destination.restoreSnapshot(snapshot, context: context)
        } catch {
            restoreError = error
        }
        XCTAssertNil(restoreError, "A fully valid archived/reviewed recovery snapshot must restore as persisted state.")
        let restored = try await destination.snapshot(context: context)
        XCTAssertEqual(restored, snapshot)
    }

    func testRedesignSnapshotRejectsSymlinkedConfiguredRootAndProjectParent() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRedesignSnapshotSymlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let binding = sourceRevision(projectID: "project-001")
        let document = try extensionDocument(binding: binding)

        let physicalRoot = temporary.appendingPathComponent("physical-root", isDirectory: true)
        let physicalStore = LocalRoomRedesignStore(rootURL: physicalRoot)
        try await physicalStore.save(document, expectedSourceRevision: binding)
        let rootAlias = temporary.appendingPathComponent("root-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: physicalRoot)
        await assertThrowsAsync {
            _ = try await LocalRoomRedesignStore(rootURL: rootAlias).snapshot(sourceRevision: binding)
        }

        let projectRoot = temporary.appendingPathComponent("project-root", isDirectory: true)
        let projectStore = LocalRoomRedesignStore(rootURL: projectRoot)
        try await projectStore.save(document, expectedSourceRevision: binding)
        let projectDirectory = projectRoot.appendingPathComponent(binding.projectID, isDirectory: true)
        let relocatedProjectDirectory = temporary.appendingPathComponent("relocated-project", isDirectory: true)
        try FileManager.default.moveItem(at: projectDirectory, to: relocatedProjectDirectory)
        try FileManager.default.createSymbolicLink(at: projectDirectory, withDestinationURL: relocatedProjectDirectory)
        await assertThrowsAsync {
            _ = try await LocalRoomRedesignStore(rootURL: projectRoot).snapshot(sourceRevision: binding)
        }
    }

    func testRedesignIdempotentRestoreRejectsSymlinkedConfiguredRootAndProjectParent() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRedesignRestoreSymlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let binding = sourceRevision(projectID: "project-001")
        let document = try extensionDocument(binding: binding)

        let physicalRoot = temporary.appendingPathComponent("physical-root", isDirectory: true)
        let physicalStore = LocalRoomRedesignStore(rootURL: physicalRoot)
        try await physicalStore.save(document, expectedSourceRevision: binding)
        let optionalSnapshot = try await physicalStore.snapshot(sourceRevision: binding)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        let rootAlias = temporary.appendingPathComponent("root-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: physicalRoot)
        await assertThrowsAsync {
            try await LocalRoomRedesignStore(rootURL: rootAlias).restoreSnapshot(
                snapshot,
                expectedSourceRevision: binding
            )
        }

        let projectRoot = temporary.appendingPathComponent("project-root", isDirectory: true)
        let projectStore = LocalRoomRedesignStore(rootURL: projectRoot)
        try await projectStore.save(document, expectedSourceRevision: binding)
        let projectDirectory = projectRoot.appendingPathComponent(binding.projectID, isDirectory: true)
        let relocatedProjectDirectory = temporary.appendingPathComponent("relocated-project", isDirectory: true)
        try FileManager.default.moveItem(at: projectDirectory, to: relocatedProjectDirectory)
        try FileManager.default.createSymbolicLink(at: projectDirectory, withDestinationURL: relocatedProjectDirectory)
        await assertThrowsAsync {
            try await LocalRoomRedesignStore(rootURL: projectRoot).restoreSnapshot(
                snapshot,
                expectedSourceRevision: binding
            )
        }
    }

    func testConceptSnapshotRejectsCaseFoldedConceptSetIDsBeforeDestinationCreation() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalConceptRecoveryCaseFold-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let binding = sourceRevision(projectID: "project-001")
        let upper = try conceptSetSnapshot(from: conceptImport(
            conceptSetID: "concept-set-A",
            attachmentID: "attachment-001",
            sourceRevision: binding,
            importedOffset: 100
        ))
        let lower = try conceptSetSnapshot(from: conceptImport(
            conceptSetID: "concept-set-a",
            attachmentID: "attachment-002",
            sourceRevision: binding,
            importedOffset: 200
        ))
        var collision = try RoomProfessionalConceptSnapshot(
            sourceRevision: binding,
            conceptSets: []
        )
        collision.conceptSets = [upper, lower]

        XCTAssertThrowsError(try collision.validateStructure())
        let destinationPackageRoot = temporary.appendingPathComponent("destination-package", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationPackageRoot, withIntermediateDirectories: false)
        let destinationRoot = temporary.appendingPathComponent("destination-concepts", isDirectory: true)
        let destination = LocalRoomConceptStore(
            rootURL: destinationRoot,
            sourcePackageRootURL: destinationPackageRoot
        )
        await assertThrowsAsync {
            try await destination.restoreSnapshot(collision, context: conceptContext(binding: binding))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.path))
    }

    func testConceptRecoveryHoldsOneRevisionLockAcrossAllPromotions() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalConceptRecoveryInterleaving-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let binding = sourceRevision(projectID: "project-001")
        let context = conceptContext(binding: binding)
        let sourcePackageRoot = temporary.appendingPathComponent("source-package", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePackageRoot, withIntermediateDirectories: false)
        let sourceStore = LocalRoomConceptStore(
            rootURL: temporary.appendingPathComponent("source-concepts", isDirectory: true),
            sourcePackageRootURL: sourcePackageRoot
        )
        _ = try await sourceStore.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-001",
                attachmentID: "attachment-001",
                sourceRevision: binding,
                importedOffset: 100
            ),
            context: context
        )
        _ = try await sourceStore.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-002",
                attachmentID: "attachment-002",
                sourceRevision: binding,
                importedOffset: 200
            ),
            context: context
        )
        let snapshot = try await sourceStore.snapshot(context: context)

        let destinationPackageRoot = temporary.appendingPathComponent(
            "destination-package",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: destinationPackageRoot, withIntermediateDirectories: false)
        let destinationRoot = temporary.appendingPathComponent(
            "destination-concepts",
            isDirectory: true
        )
        let recoveryGate = RecoveryPromotionGate(conceptSetID: "concept-set-001")
        let recoveryStore = LocalRoomConceptStore(
            rootURL: destinationRoot,
            sourcePackageRootURL: destinationPackageRoot,
            recoverySynchronizer: recoveryGate
        )
        let intruderPromotion = PromotionCommitNotifier()
        let intruderStore = LocalRoomConceptStore(
            rootURL: destinationRoot,
            sourcePackageRootURL: destinationPackageRoot,
            faultInjector: intruderPromotion
        )

        let recoveryTask = Task { () -> Result<Void, Error> in
            do {
                try await recoveryStore.restoreSnapshot(snapshot, context: context)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        guard await recoveryGate.waitForFirstPromotion() else {
            recoveryGate.resumeRecovery()
            _ = await recoveryTask.value
            return XCTFail("Recovery did not reach the first real promotion.")
        }

        var conflictingSecondSet = conceptImport(
            conceptSetID: "concept-set-002",
            attachmentID: "attachment-002",
            sourceRevision: binding,
            importedOffset: 200
        )
        conflictingSecondSet.conceptSet.request = "Concurrent Concept Set B must not replace recovery B."
        let intruderTask = Task { () -> Result<Void, Error> in
            do {
                _ = try await intruderStore.importConceptSet(conflictingSecondSet, context: context)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let intruderReachedPromotion = await intruderPromotion.waitForPromotion()

        recoveryGate.resumeRecovery()

        XCTAssertEqual(
            intruderReachedPromotion,
            .timedOut,
            "A second store must remain outside the promotion boundary until the complete recovery is committed."
        )
        switch await recoveryTask.value {
        case .success:
            break
        case .failure(let error):
            XCTFail("Recovery must not fail after promoting an earlier Concept Set: \(error)")
        }
        switch await intruderTask.value {
        case .success:
            XCTFail("The competing Concept Set must not commit over the recovered snapshot.")
        case .failure:
            break
        }

        let recoveredSnapshot = try await recoveryStore.snapshot(context: context)
        XCTAssertEqual(recoveredSnapshot, snapshot)
    }

    func testProfessionalRecoveryCoordinatorPreparesThenRestoresPackageBeforeCompanions() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinator-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let sourceProjectRoot = temporary.appendingPathComponent("source-projects", isDirectory: true)
        let sourceWorkspace = temporary.appendingPathComponent("source-working-copy", isDirectory: true)
        let archiveURL = temporary.appendingPathComponent("professional-working-set.zip")
        let sourceProjectStore = LocalRoomProjectStore(
            rootURL: sourceProjectRoot,
            clock: FixedRoomProjectClock(date: recoveryDate),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await sourceProjectStore.saveDraft(recoveryDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let sourceRevision = try await sourceProjectStore.redesignSourceRevisionBinding(
            projectID: saved.projectID,
            revisionID: saved.headRevisionID
        )

        let sourceRedesignRoot = temporary.appendingPathComponent("source-redesign", isDirectory: true)
        let sourceRedesignStore = LocalRoomRedesignStore(rootURL: sourceRedesignRoot)
        let sourceRedesign = try extensionDocument(binding: sourceRevision)
        try await sourceRedesignStore.save(sourceRedesign, expectedSourceRevision: sourceRevision)
        let sourceConceptRoot = temporary.appendingPathComponent("source-concepts", isDirectory: true)
        let sourceConceptStore = LocalRoomConceptStore(
            rootURL: sourceConceptRoot,
            sourcePackageRootURL: sourceProjectRoot
        )
        let sourceContext = conceptContext(binding: sourceRevision)
        _ = try await sourceConceptStore.importConceptSet(
            conceptImport(
                conceptSetID: "concept-set-001",
                attachmentID: "attachment-001",
                sourceRevision: sourceRevision,
                importedOffset: 100
            ),
            context: sourceContext
        )
        let optionalRedesignSnapshot = try await sourceRedesignStore.snapshot(
            sourceRevision: sourceRevision
        )
        let redesignSnapshot = try XCTUnwrap(optionalRedesignSnapshot)
        let conceptSnapshot = try await sourceConceptStore.snapshot(context: sourceContext)
        let workingCopy = try await sourceProjectStore.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: sourceWorkspace
        )
        let archive = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: workingCopy,
            archiveURL: archiveURL,
            companions: try redesignSnapshot.workingSetCompanions()
                + conceptSnapshot.workingSetCompanions()
        )
        let sourceProjectBytes = try fileSnapshot(
            at: sourceProjectRoot.appendingPathComponent(saved.projectID, isDirectory: true)
        )
        let sourceRedesignBytes = try fileSnapshot(at: sourceRedesignRoot)
        let sourceConceptBytes = try fileSnapshot(at: sourceConceptRoot)

        let recoveredProjectRoot = temporary.appendingPathComponent("recovered-projects", isDirectory: true)
        let recoveredRedesignRoot = temporary.appendingPathComponent("recovered-redesign", isDirectory: true)
        let recoveredConceptRoot = temporary.appendingPathComponent("recovered-concepts", isDirectory: true)
        let recoveryScratchRoot = temporary.appendingPathComponent("recovery-scratch", isDirectory: true)
        let recoveredProjectStore = LocalRoomProjectStore(rootURL: recoveredProjectRoot)
        let recoveredRedesignStore = LocalRoomRedesignStore(rootURL: recoveredRedesignRoot)
        let recoveredConceptStore = LocalRoomConceptStore(
            rootURL: recoveredConceptRoot,
            sourcePackageRootURL: recoveredProjectRoot
        )
        let coordinator = RoomProfessionalRecoveryCoordinator(
            projectStore: recoveredProjectStore,
            redesignStore: recoveredRedesignStore,
            conceptStore: recoveredConceptStore,
            scratchRootURL: recoveryScratchRoot
        )

        let transaction = try await coordinator.prepare(
            archiveURL: archiveURL,
            expectedDescriptor: archive.descriptor,
            target: .original
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: recoveredProjectRoot.appendingPathComponent(saved.projectID).path
            ),
            "Prepare must finish strict staging before any live package mutation."
        )

        let result = try await coordinator.resume(transaction)
        XCTAssertEqual(result.projectSummary.projectID, saved.projectID)
        XCTAssertEqual(result.projectSummary.headRevisionID, saved.headRevisionID)
        XCTAssertFalse(result.recoveredAsCopy)
        let recoveredPackage = try await recoveredProjectStore.load(projectID: saved.projectID)
        XCTAssertEqual(recoveredPackage.manifest.headRevisionID, saved.headRevisionID)
        let restoredRedesign = try await recoveredRedesignStore.load(sourceRevision: sourceRevision)
        XCTAssertEqual(restoredRedesign, sourceRedesign)
        let restoredConceptSnapshot = try await recoveredConceptStore.snapshot(context: sourceContext)
        XCTAssertEqual(restoredConceptSnapshot, conceptSnapshot)
        XCTAssertEqual(
            try fileSnapshot(at: sourceProjectRoot.appendingPathComponent(saved.projectID, isDirectory: true)),
            sourceProjectBytes
        )
        XCTAssertEqual(try fileSnapshot(at: sourceRedesignRoot), sourceRedesignBytes)
        XCTAssertEqual(try fileSnapshot(at: sourceConceptRoot), sourceConceptBytes)

        let retryResult = try await coordinator.resume(transaction)
        XCTAssertEqual(retryResult, result)
    }

    func testProfessionalRecoveryCoordinatorRestoresAllConceptSetsBeforeAnotherStoreCanCommitB() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorConceptInterleaving-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let fixture = try await coordinatorFixture(in: temporary)
        let recoveryConceptStore = LocalRoomConceptStore(
            rootURL: fixture.recoveredConceptRoot,
            sourcePackageRootURL: fixture.recoveredProjectRoot
        )
        let betweenConceptSets = BlockingProfessionalRecoveryFaultInjector(
            point: .afterConceptPromotionBeforePhaseUpdate
        )
        let coordinator = RoomProfessionalRecoveryCoordinator(
            projectStore: fixture.recoveredProjectStore,
            redesignStore: fixture.recoveredRedesignStore,
            conceptStore: recoveryConceptStore,
            scratchRootURL: fixture.recoveryScratchRoot,
            faultInjector: betweenConceptSets
        )
        let transaction = try await coordinator.prepare(
            archiveURL: fixture.archiveURL,
            expectedDescriptor: fixture.descriptor,
            target: .original
        )

        let recovery = Task { () -> Result<RoomProfessionalRecoveryResult, Error> in
            do {
                return .success(try await coordinator.resume(transaction))
            } catch {
                return .failure(error)
            }
        }
        guard await betweenConceptSets.waitUntilBlocked() else {
            betweenConceptSets.continueRecovery()
            _ = await recovery.value
            return XCTFail("Coordinator did not reach the post-Concept recovery boundary.")
        }

        var competingImport = conceptImport(
            conceptSetID: "concept-set-002",
            attachmentID: "attachment-002",
            sourceRevision: fixture.sourceRevision,
            importedOffset: 200
        )
        competingImport.conceptSet.request = "Concurrent Concept Set B must not replace recovered B."
        let competingPromotion = PromotionCommitNotifier()
        let competingStore = LocalRoomConceptStore(
            rootURL: fixture.recoveredConceptRoot,
            sourcePackageRootURL: fixture.recoveredProjectRoot,
            faultInjector: competingPromotion
        )
        let competing = Task { () -> Result<Void, Error> in
            do {
                _ = try await competingStore.importConceptSet(
                    competingImport,
                    context: fixture.sourceContext
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let competingReachedPromotion = await competingPromotion.waitForPromotion()

        betweenConceptSets.continueRecovery()

        XCTAssertEqual(
            competingReachedPromotion,
            .timedOut,
            "A second store must not commit B between the coordinator's recovered A and B."
        )
        switch await recovery.value {
        case .success:
            break
        case .failure(let error):
            XCTFail("Coordinator recovery must not fail after recovering A: \(error)")
        }
        switch await competing.value {
        case .success:
            XCTFail("The competing Concept Set B must not commit over the recovered snapshot.")
        case .failure:
            break
        }
        let recoveredSnapshot = try await recoveryConceptStore.snapshot(context: fixture.sourceContext)
        XCTAssertEqual(recoveredSnapshot, fixture.sourceConceptSnapshot)
    }

    func testProfessionalRecoveryCoordinatorRecoverAsCopyUsesOneStoreDerivedCopyAcrossPostPackageCrash() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorCopyCrash-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixture = try await coordinatorFixture(in: temporary, targetHasDivergentOriginal: true)
        let transaction = try await fixture.coordinator(
            faultInjector: FailingRoomProfessionalRecoveryFaultInjector(
                point: .afterPackagePromotionBeforePhaseUpdate
            )
        ).prepare(
            archiveURL: fixture.archiveURL,
            expectedDescriptor: fixture.descriptor,
            target: .recoveredCopy(projectID: "project-copy")
        )

        do {
            _ = try await fixture.coordinator(
                faultInjector: FailingRoomProfessionalRecoveryFaultInjector(
                    point: .afterPackagePromotionBeforePhaseUpdate
                )
            ).resume(transaction)
            XCTFail("Expected the deterministic post-package journal gap.")
        } catch {
            XCTAssertEqual(
                error as? RoomProfessionalRecoveryCoordinatorError,
                .injectedFailure(.afterPackagePromotionBeforePhaseUpdate)
            )
        }
        let firstCopyBinding = try await fixture.recoveredProjectStore.redesignSourceRevisionBinding(
            projectID: "project-copy",
            revisionID: fixture.sourceSummary.headRevisionID
        )
        XCTAssertNotEqual(firstCopyBinding.semanticSHA256, fixture.sourceRevision.semanticSHA256)
        XCTAssertNotEqual(
            firstCopyBinding.revisionManifestSHA256,
            fixture.sourceRevision.revisionManifestSHA256
        )
        let copiedRedesignBeforeResume = try await fixture.recoveredRedesignStore.load(
            sourceRevision: firstCopyBinding
        )
        XCTAssertNil(copiedRedesignBeforeResume)

        let restartedProjectStore = LocalRoomProjectStore(rootURL: fixture.recoveredProjectRoot)
        let restartedRedesignStore = LocalRoomRedesignStore(rootURL: fixture.recoveredRedesignRoot)
        let restartedConceptStore = LocalRoomConceptStore(
            rootURL: fixture.recoveredConceptRoot,
            sourcePackageRootURL: fixture.recoveredProjectRoot
        )
        let restarted = RoomProfessionalRecoveryCoordinator(
            projectStore: restartedProjectStore,
            redesignStore: restartedRedesignStore,
            conceptStore: restartedConceptStore,
            scratchRootURL: fixture.recoveryScratchRoot
        )
        let result = try await restarted.resume(transaction)
        XCTAssertTrue(result.recoveredAsCopy)
        XCTAssertEqual(result.projectSummary.projectID, "project-copy")
        let recoveredBinding = try await restartedProjectStore.redesignSourceRevisionBinding(
            projectID: "project-copy",
            revisionID: fixture.sourceSummary.headRevisionID
        )
        XCTAssertEqual(recoveredBinding, firstCopyBinding)
        let recoveredRedesign = try await restartedRedesignStore.load(sourceRevision: recoveredBinding)
        XCTAssertEqual(recoveredRedesign?.sourceRevision, recoveredBinding)
        let copyContext = conceptContext(binding: recoveredBinding)
        let recoveredConcepts = try await restartedConceptStore.snapshot(context: copyContext)
        XCTAssertEqual(recoveredConcepts.sourceRevision, recoveredBinding)
        XCTAssertEqual(recoveredConcepts.conceptSets.count, 2)
        XCTAssertEqual(
            try fileSnapshot(
                at: fixture.sourceProjectRoot.appendingPathComponent(
                    fixture.sourceSummary.projectID,
                    isDirectory: true
                )
            ),
            fixture.sourceProjectBytes
        )
        XCTAssertEqual(try fileSnapshot(at: fixture.sourceRedesignRoot), fixture.sourceRedesignBytes)
        XCTAssertEqual(try fileSnapshot(at: fixture.sourceConceptRoot), fixture.sourceConceptBytes)
        let retryResult = try await restarted.resume(transaction)
        XCTAssertEqual(retryResult, result)
    }

    func testProfessionalRecoveryCoordinatorResumesEveryPackageFirstCrashWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorFaults-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for point in RoomProfessionalRecoveryFaultPoint.allCases where point != .afterTransactionDirectoryCreationBeforeOwnershipMarker {
            let temporary = root.appendingPathComponent(point.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            let fixture = try await coordinatorFixture(in: temporary)
            let failing = fixture.coordinator(
                faultInjector: FailingRoomProfessionalRecoveryFaultInjector(point: point)
            )
            let transaction = try await failing.prepare(
                archiveURL: fixture.archiveURL,
                expectedDescriptor: fixture.descriptor,
                target: .original
            )
            do {
                _ = try await failing.resume(transaction)
                XCTFail("Expected deterministic failure at \(point.rawValue).")
            } catch {
                XCTAssertEqual(
                    error as? RoomProfessionalRecoveryCoordinatorError,
                    .injectedFailure(point)
                )
            }

            let packageURL = fixture.recoveredProjectRoot.appendingPathComponent(
                fixture.sourceSummary.projectID,
                isDirectory: true
            )
            if point == .beforePackageCommit {
                XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveredRedesignRoot.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveredConceptRoot.path))
            } else {
                XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
            }

            let resumed = fixture.coordinator()
            let result = try await resumed.resume(transaction)
            XCTAssertFalse(result.recoveredAsCopy)
            XCTAssertEqual(result.projectSummary.projectID, fixture.sourceSummary.projectID)
            let restoredRedesign = try await fixture.recoveredRedesignStore.load(
                sourceRevision: fixture.sourceRevision
            )
            XCTAssertEqual(restoredRedesign, fixture.sourceRedesign)
            let restoredConcepts = try await fixture.recoveredConceptStore.snapshot(
                context: fixture.sourceContext
            )
            XCTAssertEqual(restoredConcepts, fixture.sourceConceptSnapshot)
        }
    }

    func testProfessionalRecoveryCoordinatorRejectsTamperedStagedArchiveBeforeLiveMutation() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorTamper-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixture = try await coordinatorFixture(in: temporary)
        let coordinator = fixture.coordinator()
        let transaction = try await coordinator.prepare(
            archiveURL: fixture.archiveURL,
            expectedDescriptor: fixture.descriptor,
            target: .original
        )
        let transactionDirectory = fixture.recoveryScratchRoot
            .appendingPathComponent(".roomscan-professional-recovery-\(transaction.transactionID)")
        let stagedArchive = transactionDirectory.appendingPathComponent("working-set.zip")
        try Data("tampered staged working set".utf8).write(to: stagedArchive)

        await assertThrowsAsync {
            _ = try await coordinator.resume(transaction)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.recoveredProjectRoot.appendingPathComponent(
                    fixture.sourceSummary.projectID
                ).path
            )
        )
        XCTAssertEqual(
            try fileSnapshot(
                at: fixture.sourceProjectRoot.appendingPathComponent(
                    fixture.sourceSummary.projectID,
                    isDirectory: true
                )
            ),
            fixture.sourceProjectBytes
        )
    }

    func testProfessionalRecoveryCoordinatorJournalIsConfidentialAndRejectsSymlinkedMarker() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorJournal-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixture = try await coordinatorFixture(in: temporary)
        let coordinator = fixture.coordinator()
        let transaction = try await coordinator.prepare(
            archiveURL: fixture.archiveURL,
            expectedDescriptor: fixture.descriptor,
            target: .original
        )
        let transactionDirectory = fixture.recoveryScratchRoot
            .appendingPathComponent(".roomscan-professional-recovery-\(transaction.transactionID)")
        let journalURL = transactionDirectory.appendingPathComponent("recovery-journal.json")
        let journalData = try Data(contentsOf: journalURL)
        let journalText = try XCTUnwrap(String(data: journalData, encoding: .utf8))
        XCTAssertFalse(journalText.contains(fixture.archiveURL.path))
        XCTAssertFalse(journalText.contains(fixture.sourceProjectRoot.path))
        XCTAssertFalse(journalText.contains("Preserve the captured shell."))
        XCTAssertFalse(journalText.contains("A warmer concept"))

        let ownershipMarkerURL = transactionDirectory.appendingPathComponent(
            ".roomscan-professional-recovery-ownership.json"
        )
        let ownershipMarkerData = try Data(contentsOf: ownershipMarkerURL)
        let ownershipMarkerText = try XCTUnwrap(String(data: ownershipMarkerData, encoding: .utf8))
        XCTAssertFalse(ownershipMarkerText.contains(fixture.archiveURL.path))
        XCTAssertFalse(ownershipMarkerText.contains(fixture.sourceProjectRoot.path))
        XCTAssertFalse(ownershipMarkerText.contains("Preserve the captured shell."))
        XCTAssertFalse(ownershipMarkerText.contains("A warmer concept"))

        let relocatedJournal = temporary.appendingPathComponent("relocated-journal.json")
        try FileManager.default.moveItem(at: journalURL, to: relocatedJournal)
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: relocatedJournal)
        await assertThrowsAsync {
            _ = try await coordinator.resume(transaction)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.recoveredProjectRoot.appendingPathComponent(
                    fixture.sourceSummary.projectID
                ).path
            )
        )
    }

    func testProfessionalRecoveryCoordinatorPreservesAIReadyAutomaticMappingsForOriginalAndDowngradesCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorAIReadyProvenance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let originalFixture = try await coordinatorFixture(
            in: root.appendingPathComponent("original", isDirectory: true),
            automaticPackageProfile: .aiReady
        )
        let originalTransaction = try await originalFixture.coordinator().prepare(
            archiveURL: originalFixture.archiveURL,
            expectedDescriptor: originalFixture.descriptor,
            target: .original
        )
        let originalResult = try await originalFixture.coordinator().resume(originalTransaction)
        XCTAssertEqual(originalResult.conceptMappingAdjustments, [])
        XCTAssertEqual(
            originalResult.conceptSourcePackageProvenance.map(\.canonicalManifestData),
            [try XCTUnwrap(originalFixture.sourcePackageManifestData)]
        )
        let originalContext = try recoveryConceptContext(
            binding: originalFixture.sourceRevision,
            redesign: originalFixture.sourceRedesign,
            provenance: originalResult.conceptSourcePackageProvenance
        )
        let originalConcept = try await originalFixture.recoveredConceptStore.load(
            conceptSetID: "concept-set-001",
            context: originalContext
        )
        XCTAssertEqual(
            originalConcept.attachments.first?.mapping,
            .automatic(cameraID: "canonical-entry")
        )

        let copyFixture = try await coordinatorFixture(
            in: root.appendingPathComponent("copy", isDirectory: true),
            targetHasDivergentOriginal: true,
            automaticPackageProfile: .aiReady
        )
        let copyTransaction = try await copyFixture.coordinator().prepare(
            archiveURL: copyFixture.archiveURL,
            expectedDescriptor: copyFixture.descriptor,
            target: .recoveredCopy(projectID: "project-copy")
        )
        let copyResult = try await copyFixture.coordinator().resume(copyTransaction)
        let copyBinding = try await copyFixture.recoveredProjectStore.redesignSourceRevisionBinding(
            projectID: "project-copy",
            revisionID: copyFixture.sourceSummary.headRevisionID
        )
        XCTAssertEqual(copyResult.conceptSourcePackageProvenance, [])
        XCTAssertEqual(
            copyResult.conceptMappingAdjustments,
            [try RoomProfessionalConceptMappingAdjustment(
                conceptSetID: "concept-set-001",
                attachmentID: "attachment-001",
                from: .automatic(cameraID: "canonical-entry"),
                to: .manual(cameraID: "canonical-entry")
            )]
        )
        let loadedCopiedRedesign = try await copyFixture.recoveredRedesignStore.load(
            sourceRevision: copyBinding
        )
        let copiedRedesign = try XCTUnwrap(loadedCopiedRedesign)
        let copyContext = try recoveryConceptContext(
            binding: copyBinding,
            redesign: copiedRedesign,
            provenance: []
        )
        let copiedConcept = try await copyFixture.recoveredConceptStore.load(
            conceptSetID: "concept-set-001",
            context: copyContext
        )
        XCTAssertEqual(
            copiedConcept.attachments.first?.mapping,
            .manual(cameraID: "canonical-entry")
        )
        let copiedAttachment = try await copyFixture.recoveredConceptStore.attachmentData(
            conceptSetID: "concept-set-001",
            attachmentID: "attachment-001",
            context: copyContext
        )
        XCTAssertEqual(copiedAttachment, Self.safePNG)
    }

    func testCompletePackageProvenanceIsRejectedFromWorkingSetAndDowngradedWithoutMutatingSource() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorCompleteProvenance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixture = try await coordinatorFixture(
            in: temporary,
            automaticPackageProfile: .complete
        )
        let completeManifestData = try XCTUnwrap(fixture.sourcePackageManifestData)
        XCTAssertThrowsError(
            try RoomProfessionalConceptSourcePackageProvenanceSnapshot(
                sourceRevision: fixture.sourceRevision,
                canonicalManifestData: completeManifestData
            )
        )
        XCTAssertFalse(fixture.archive.manifest.entries.contains(where: {
            if case .conceptSourcePackageProvenance = $0.kind { return true }
            return false
        }))
        XCTAssertEqual(
            fixture.archive.conceptMappingAdjustments,
            [try RoomProfessionalConceptMappingAdjustment(
                conceptSetID: "concept-set-001",
                attachmentID: "attachment-001",
                from: .automatic(cameraID: "canonical-entry"),
                to: .manual(cameraID: "canonical-entry")
            )]
        )

        let transaction = try await fixture.coordinator().prepare(
            archiveURL: fixture.archiveURL,
            expectedDescriptor: fixture.descriptor,
            target: .original
        )
        let result = try await fixture.coordinator().resume(transaction)
        XCTAssertEqual(result.conceptSourcePackageProvenance, [])
        XCTAssertEqual(result.conceptMappingAdjustments, fixture.archive.conceptMappingAdjustments)
        let recoveredContext = try recoveryConceptContext(
            binding: fixture.sourceRevision,
            redesign: fixture.sourceRedesign,
            provenance: []
        )
        let recoveredConcept = try await fixture.recoveredConceptStore.load(
            conceptSetID: "concept-set-001",
            context: recoveredContext
        )
        XCTAssertEqual(
            recoveredConcept.attachments.first?.mapping,
            .manual(cameraID: "canonical-entry")
        )
        let sourceConceptSnapshot = try XCTUnwrap(fixture.sourceConceptSnapshot.conceptSets.first)
        let sourceConcept = try sourceConceptSnapshot.validatedConcept()
        XCTAssertEqual(sourceConcept.attachments.first?.mapping, .automatic(cameraID: "canonical-entry"))
    }

    func testConceptTransportAllowsEmptyCameraSetForManualAndUnmatchedOnlyConcepts() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorEmptyCameraSet-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixture = try await coordinatorFixture(in: temporary)

        let transport = try RoomProfessionalConceptTransportSnapshot(
            sourceSnapshot: fixture.sourceConceptSnapshot,
            sourcePackageManifestData: [],
            currentCanonicalCameraIDs: []
        )
        XCTAssertEqual(transport.conceptSnapshot, fixture.sourceConceptSnapshot)
        XCTAssertEqual(transport.sourcePackageProvenance, [])
        XCTAssertEqual(transport.conceptMappingAdjustments, [])
    }

    func testProfessionalSyncGoldenFixturesAreByteIdenticalCoreBuilderOutputs() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalSyncGoldenFixtureBuild-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        // This is a real AI-ready automatic Concept archive: its source
        // package provenance is part of the strict outer closure.
        let workingFixture = try await coordinatorFixture(
            in: temporary.appendingPathComponent("working", isDirectory: true),
            automaticPackageProfile: .aiReady,
            deterministicOwnershipTransactions: true
        )
        let workingArchiveData = try Data(contentsOf: workingFixture.archiveURL)
        let workingDescriptorData = try RoomProfessionalSyncCanonicalJSON.encode(
            workingFixture.descriptor
        )
        let workingManifestData = try RoomProfessionalSyncCanonicalJSON.encode(
            workingFixture.archive.manifest
        )
        XCTAssertTrue(workingFixture.archive.manifest.entries.contains {
            if case .conceptSourcePackageProvenance = $0.kind { return true }
            return false
        })

        // The reviewed raw control is deliberately synthetic and remains a
        // separate tier; no sensitive/captured bytes are checked in.
        let rawFixture = try await goldenRawFixture(
            in: temporary.appendingPathComponent("raw", isDirectory: true),
            sourceRevision: workingFixture.sourceRevision
        )
        let rawArchiveData = try Data(contentsOf: rawFixture.archiveURL)
        let rawDescriptorData = try RoomProfessionalSyncCanonicalJSON.encode(
            rawFixture.descriptor
        )
        let rawManifestData = try RoomProfessionalSyncCanonicalJSON.encode(rawFixture.manifest)

        let fixtureRoot = professionalSyncFixtureRoot()
        let requiredFixtureURLs = [
            fixtureRoot.appendingPathComponent("working-set-v1.zip.base64"),
            fixtureRoot.appendingPathComponent("working-set-v1.descriptor.base64"),
            fixtureRoot.appendingPathComponent("working-set-v1.manifest-sha256.txt"),
            fixtureRoot.appendingPathComponent("reviewed-raw-v1.zip.base64"),
            fixtureRoot.appendingPathComponent("reviewed-raw-v1.descriptor.base64"),
            fixtureRoot.appendingPathComponent("reviewed-raw-v1.manifest-sha256.txt")
        ]
        guard requiredFixtureURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            print("WORKING_ARCHIVE_BASE64=\(workingArchiveData.base64EncodedString())")
            print("WORKING_DESCRIPTOR_BASE64=\(workingDescriptorData.base64EncodedString())")
            print("WORKING_MANIFEST_SHA256=\(RoomSHA256.hexDigest(of: workingManifestData))")
            print("RAW_ARCHIVE_BASE64=\(rawArchiveData.base64EncodedString())")
            print("RAW_DESCRIPTOR_BASE64=\(rawDescriptorData.base64EncodedString())")
            print("RAW_MANIFEST_SHA256=\(RoomSHA256.hexDigest(of: rawManifestData))")
            XCTFail("Missing ProfessionalSync golden fixture files. Capture the real Core-builder output above.")
            return
        }

        XCTAssertEqual(
            workingArchiveData,
            try goldenFixtureBase64Data(named: "working-set-v1.zip.base64")
        )
        XCTAssertEqual(
            workingDescriptorData,
            try goldenFixtureBase64Data(named: "working-set-v1.descriptor.base64")
        )
        XCTAssertEqual(
            RoomSHA256.hexDigest(of: workingManifestData),
            try goldenFixtureString(named: "working-set-v1.manifest-sha256.txt")
        )

        XCTAssertEqual(
            rawArchiveData,
            try goldenFixtureBase64Data(named: "reviewed-raw-v1.zip.base64")
        )
        XCTAssertEqual(
            rawDescriptorData,
            try goldenFixtureBase64Data(named: "reviewed-raw-v1.descriptor.base64")
        )
        XCTAssertEqual(
            RoomSHA256.hexDigest(of: rawManifestData),
            try goldenFixtureString(named: "reviewed-raw-v1.manifest-sha256.txt")
        )

        let workingExtraction = temporary.appendingPathComponent("working-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: workingExtraction, withIntermediateDirectories: false)
        let extractedWorking = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
            archiveURL: workingFixture.archiveURL,
            expectedDescriptor: workingFixture.descriptor,
            into: workingExtraction
        )
        XCTAssertEqual(extractedWorking.manifest, workingFixture.archive.manifest)
        XCTAssertFalse(extractedWorking.manifest.entries.contains {
            if case .conceptSourcePackageProvenance = $0.kind { return false }
            return $0.path.contains("raw") || $0.path.contains("world-map")
        })

        let rawExtraction = temporary.appendingPathComponent("raw-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: rawExtraction, withIntermediateDirectories: false)
        let extractedRaw = try await RoomProfessionalRawArchive.extractAndVerify(
            archiveURL: rawFixture.archiveURL,
            expectedDescriptor: rawFixture.descriptor,
            into: rawExtraction
        )
        XCTAssertEqual(extractedRaw.manifest, rawFixture.manifest)
        XCTAssertEqual(extractedRaw.manifest.entries.map(\.assetClass), [.rgb])
    }

    func testProfessionalRecoveryCoordinatorRetainsOnlyMarkerOwnedStagesAndDiscardsAfterAcknowledgement() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixture = try await coordinatorFixture(in: temporary)
        let coordinator = fixture.coordinator()
        let transaction = try await coordinator.prepare(
            archiveURL: fixture.archiveURL,
            expectedDescriptor: fixture.descriptor,
            target: .original
        )
        let first = try await coordinator.resume(transaction)
        let second = try await coordinator.resume(transaction)
        XCTAssertEqual(second, first)
        let transactionDirectory = fixture.recoveryScratchRoot
            .appendingPathComponent(".roomscan-professional-recovery-\(transaction.transactionID)")
        let transactionChildren = try FileManager.default.contentsOfDirectory(atPath: transactionDirectory.path)
        XCTAssertFalse(transactionChildren.contains { $0.hasPrefix(".verification-") })

        try await coordinator.discardCompleted(transaction)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transactionDirectory.path))
        await assertThrowsAsync {
            _ = try await coordinator.resume(transaction)
        }
    }

    func testProfessionalRecoveryCoordinatorLeavesUnmarkedCandidateWhenOwnershipWriteFailsBeforeBytes() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorOwnershipFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixture = try await coordinatorFixture(in: temporary)
        let coordinator = fixture.coordinator(
            faultInjector: FailingRoomProfessionalRecoveryFaultInjector(
                point: .afterTransactionDirectoryCreationBeforeOwnershipMarker
            )
        )
        await assertThrowsAsync {
            _ = try await coordinator.prepare(
                archiveURL: fixture.archiveURL,
                expectedDescriptor: fixture.descriptor,
                target: .original
            )
        }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: fixture.recoveryScratchRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".roomscan-professional-recovery-") }
        XCTAssertEqual(candidates.count, 1)
        let candidateChildren = try FileManager.default.contentsOfDirectory(atPath: candidates[0].path)
        XCTAssertFalse(candidateChildren.contains("working-set.zip"))
        XCTAssertFalse(candidateChildren.contains(".roomscan-professional-recovery-ownership.json"))
    }

    func testProfessionalRecoveryCoordinatorRejectsRecomputedCorruptPackageAndCompanionBeforeLiveMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProfessionalRecoveryCoordinatorCorruptEntries-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for fixtureKind in ["companion", "package"] {
            let temporary = root.appendingPathComponent(fixtureKind, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            let fixture = try await coordinatorFixture(in: temporary)
            try FileManager.default.createDirectory(
                at: fixture.recoveryScratchRoot,
                withIntermediateDirectories: true
            )
            let unknownSibling = fixture.recoveryScratchRoot.appendingPathComponent(
                ".roomscan-professional-recovery-unmarked-sibling",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: unknownSibling, withIntermediateDirectories: false)
            try Data("do not delete unknown scratch".utf8).write(
                to: unknownSibling.appendingPathComponent("retained.txt")
            )
            let replacementPath = fixtureKind == "companion"
                ? "companions/redesign.json"
                : RoomProfessionalWorkingSetArchive.packageBackupEntryPath
            let forgedArchive = temporary.appendingPathComponent("forged-\(fixtureKind).zip")
            let forgedDescriptor = try await forgeWorkingSetReplacingEntry(
                archiveURL: fixture.archiveURL,
                descriptor: fixture.descriptor,
                replacementPath: replacementPath,
                replacementData: Data("world-map bytes must never become a companion or package".utf8),
                destinationArchiveURL: forgedArchive,
                workspace: temporary.appendingPathComponent("forge", isDirectory: true)
            )
            await assertThrowsAsync {
                _ = try await fixture.coordinator().prepare(
                    archiveURL: forgedArchive,
                    expectedDescriptor: forgedDescriptor,
                    target: .original
                )
            }
            // This keeps the no-live-mutation assertion meaningful for the
            // isolated guard-neutralization control: if a compromised
            // pre-live validator ever accepts this forged stage, exercising
            // its returned transaction must still leave no live package.
            let unexpectedTransaction = try? await fixture.coordinator().prepare(
                archiveURL: forgedArchive,
                expectedDescriptor: forgedDescriptor,
                target: .original
            )
            if let unexpectedTransaction {
                _ = try? await fixture.coordinator().resume(unexpectedTransaction)
            }
            XCTAssertNil(unexpectedTransaction)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.recoveredProjectRoot.appendingPathComponent(
                        fixture.sourceSummary.projectID
                    ).path
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveredRedesignRoot.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveredConceptRoot.path))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryScratchRoot.path).sorted(),
                [unknownSibling.lastPathComponent]
            )
        }
    }

    private final class RecoveryPromotionGate: RoomConceptRecoverySynchronizing, @unchecked Sendable {
        let firstPromotion = DispatchSemaphore(value: 0)

        private let allowedToContinue = DispatchSemaphore(value: 0)
        private let conceptSetID: String

        init(conceptSetID: String) {
            self.conceptSetID = conceptSetID
        }

        func didPromoteRecoveredConceptSet(_ conceptSetID: String) {
            guard conceptSetID == self.conceptSetID else { return }
            firstPromotion.signal()
            _ = allowedToContinue.wait(timeout: .distantFuture)
        }

        func waitForFirstPromotion() async -> Bool {
            await Task.detached { [firstPromotion] in
                Self.wait(for: firstPromotion) == .success
            }.value
        }

        func resumeRecovery() {
            allowedToContinue.signal()
        }

        private static func wait(for semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + 2)
        }
    }

    private final class PromotionCommitNotifier: RoomConceptStoreFaultInjecting, @unchecked Sendable {
        let promoted = DispatchSemaphore(value: 0)

        func throwIfNeeded(at point: RoomConceptStoreFaultPoint) throws {
            guard point == .afterPromotionBeforeCommit else { return }
            promoted.signal()
        }

        func waitForPromotion() async -> DispatchTimeoutResult {
            await Task.detached { [promoted] in
                Self.wait(for: promoted)
            }.value
        }

        private static func wait(for semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + 2)
        }
    }

    private final class BlockingProfessionalRecoveryFaultInjector: RoomProfessionalRecoveryFaultInjecting, @unchecked Sendable {
        private let reached = DispatchSemaphore(value: 0)
        private let allowedToContinue = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var hasBlocked = false
        private let point: RoomProfessionalRecoveryFaultPoint

        init(point: RoomProfessionalRecoveryFaultPoint) {
            self.point = point
        }

        func throwIfNeeded(at point: RoomProfessionalRecoveryFaultPoint) throws {
            guard point == self.point else { return }
            lock.lock()
            let shouldBlock = !hasBlocked
            hasBlocked = true
            lock.unlock()
            guard shouldBlock else { return }
            reached.signal()
            _ = allowedToContinue.wait(timeout: .distantFuture)
        }

        func waitUntilBlocked() async -> Bool {
            await Task.detached { [reached] in
                Self.wait(for: reached) == .success
            }.value
        }

        func continueRecovery() {
            allowedToContinue.signal()
        }

        private static func wait(for semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + 2)
        }
    }

    private func sourceRevision(projectID: String) -> RoomRedesignSourceRevision {
        RoomRedesignSourceRevision(
            projectID: projectID,
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: digestA,
            revisionManifestSHA256: digestB
        )
    }

    private var recoveryDate: Date {
        Date(timeIntervalSince1970: 1_704_067_200)
    }

    private func recoveryDraft() throws -> RoomDraft {
        let transform = RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
        return RoomDraft(
            metadata: RoomMetadata(
                projectID: "pending-project",
                customName: "Professional recovery room",
                captureDate: recoveryDate,
                lastRevisedDate: recoveryDate,
                manualLocation: "",
                optionalGPS: nil,
                notes: "",
                tags: [],
                thumbnailRelativePath: nil,
                archived: false
            ),
            revision: RoomRevisionPayload(
                semanticSnapshot: RoomSemanticSnapshot(
                    projectID: "pending-project",
                    revisionID: "pending-revision",
                    units: "meters",
                    accuracyDisclaimer: "Measurements are estimates, not survey-grade evidence.",
                    structuralElements: [
                        RoomSemanticElement(
                            id: "floor-001",
                            kind: "floor",
                            label: "Floor",
                            dimensionsMeters: .init(width: 4, height: 0.05, depth: 3),
                            transform: transform,
                            provenance: .init(
                                framework: "test",
                                sourceIdentifier: "floor",
                                captureAttemptID: "attempt-001",
                                coordinateSpaceEpochID: "epoch-001"
                            ),
                            mobility: .structural,
                            origin: .deterministicFixture
                        )
                    ],
                    objectElements: []
                ),
                annotations: [],
                measurements: [],
                photos: []
            )
        )
    }

    private func extensionDocument(binding: RoomRedesignSourceRevision) throws -> RoomLocalRedesignExtensionV2 {
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: binding,
            input: .init(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: -1, y: 0, z: -1),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: .init(
                    minimum: .init(x: -2, y: 0, z: -2),
                    maximum: .init(x: 2, y: 2.5, z: 2)
                ),
                referenceWallFeatureID: nil
            )
        )
        return RoomLocalRedesignExtensionV2(
            sourceRevision: binding,
            orientation: orientation,
            redesignIntent: RoomRedesignIntentV2(
                request: "Preserve the captured shell.",
                scope: .stage,
                constraints: nil,
                permissions: []
            ),
            propertyMembership: nil,
            conceptMetadata: []
        )
    }

    private func storeDerivedCopyBindings(
        in temporary: URL
    ) async throws -> (
        original: RoomRedesignSourceRevision,
        copy: RoomRedesignSourceRevision,
        mapping: RoomProfessionalRecoveredCopyMapping
    ) {
        let sourceRoot = temporary.appendingPathComponent("binding-source-projects", isDirectory: true)
        let sourceWorkspace = temporary.appendingPathComponent("binding-source-workspace", isDirectory: true)
        let sourceArchive = temporary.appendingPathComponent("binding-source.zip")
        let sourceStore = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: recoveryDate),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let sourceSavedResult = try await sourceStore.saveDraft(recoveryDraft(), decision: .save)
        let sourceSaved = try XCTUnwrap(sourceSavedResult)
        let original = try await sourceStore.redesignSourceRevisionBinding(
            projectID: sourceSaved.projectID,
            revisionID: sourceSaved.headRevisionID
        )
        let materialization = try await sourceStore.materializeBackupSnapshot(
            projectID: sourceSaved.projectID,
            expectedHeadRevisionID: sourceSaved.headRevisionID,
            into: sourceWorkspace
        )
        let backup = try await RoomProjectBackupArchive.build(
            materialization: materialization,
            archiveURL: sourceArchive
        )

        let destinationRoot = temporary.appendingPathComponent("binding-destination-projects", isDirectory: true)
        let destinationWorkspace = temporary.appendingPathComponent(
            "binding-destination-workspace",
            isDirectory: true
        )
        let destinationStore = LocalRoomProjectStore(
            rootURL: destinationRoot,
            clock: FixedRoomProjectClock(date: recoveryDate),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        var divergentDraft = try recoveryDraft()
        divergentDraft.metadata.customName = "Divergent destination"
        _ = try await destinationStore.saveDraft(divergentDraft, decision: .save)
        let preparation = try await destinationStore.prepareRecovery(
            archiveURL: sourceArchive,
            expectedCloudDescriptor: backup.descriptor,
            into: destinationWorkspace
        )
        let result = try await destinationStore.commitPreparedRecovery(
            preparation,
            conflictPolicy: .recoverAsCopy,
            recoveredCopyProjectID: "project-copy"
        )
        guard case .recoveredCopy = result else {
            throw RoomProfessionalRecoveryError.invalidMapping(
                "The test fixture did not create the expected recovered package copy."
            )
        }
        let copy = try await destinationStore.redesignSourceRevisionBinding(
            projectID: "project-copy",
            revisionID: sourceSaved.headRevisionID
        )
        return (
            original,
            copy,
            try RoomProfessionalRecoveredCopyMapping.storeDerived(
                original: original,
                recoveredCopy: copy
            )
        )
    }

    private struct CoordinatorFixture {
        let archiveURL: URL
        let descriptor: RoomProfessionalWorkingSetDescriptor
        let archive: RoomProfessionalWorkingSetSnapshot
        let sourceSummary: RoomProjectSummary
        let sourceRevision: RoomRedesignSourceRevision
        let sourceContext: RoomConceptSetValidationContext
        let sourceRedesign: RoomLocalRedesignExtensionV2
        let sourceConceptSnapshot: RoomProfessionalConceptSnapshot
        let sourcePackageManifestData: Data?
        let sourceProjectRoot: URL
        let sourceProjectBytes: [String: Data]
        let sourceRedesignRoot: URL
        let sourceRedesignBytes: [String: Data]
        let sourceConceptRoot: URL
        let sourceConceptBytes: [String: Data]
        let recoveredProjectRoot: URL
        let recoveredRedesignRoot: URL
        let recoveredConceptRoot: URL
        let recoveryScratchRoot: URL
        let recoveredProjectStore: LocalRoomProjectStore
        let recoveredRedesignStore: LocalRoomRedesignStore
        let recoveredConceptStore: LocalRoomConceptStore

        func coordinator() -> RoomProfessionalRecoveryCoordinator {
            coordinator(faultInjector: NoRoomProfessionalRecoveryFaultInjector())
        }

        func coordinator(
            faultInjector: any RoomProfessionalRecoveryFaultInjecting
        ) -> RoomProfessionalRecoveryCoordinator {
            RoomProfessionalRecoveryCoordinator(
                projectStore: recoveredProjectStore,
                redesignStore: recoveredRedesignStore,
                conceptStore: recoveredConceptStore,
                scratchRootURL: recoveryScratchRoot,
                faultInjector: faultInjector
            )
        }
    }

    private func goldenRawFixture(
        in temporary: URL,
        sourceRevision: RoomRedesignSourceRevision
    ) async throws -> RoomProfessionalRawArchiveSnapshot {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let sourceURL = temporary.appendingPathComponent("synthetic-reviewed-rgb.bin")
        try Data("synthetic-reviewed-raw-rgb-v1".utf8).write(to: sourceURL)
        let input = try RoomProfessionalRawArchiveInput(
            assetID: "synthetic-rgb-001",
            assetClass: .rgb,
            sourceURL: sourceURL,
            archivePath: "raw/rgb-synthetic-001.bin",
            mediaType: "application/octet-stream"
        )
        let selection = try await RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: sourceRevision,
            inputs: [input]
        )
        let review = try RoomRawDisclosureReview(
            reviewID: "synthetic-raw-review-001",
            sourceRevision: sourceRevision,
            reviewedSelectionSHA256: selection,
            reviewedAt: recoveryDate,
            decision: .accepted
        )
        return try await RoomProfessionalRawArchive.build(
            sourceRevision: sourceRevision,
            review: review,
            inputs: [input],
            archiveURL: temporary.appendingPathComponent("reviewed-raw-v1.zip")
        )
    }

    private func professionalSyncFixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProfessionalSync", isDirectory: true)
    }

    private func goldenFixtureBase64Data(named name: String) throws -> Data {
        let data = try Data(contentsOf: professionalSyncFixtureRoot().appendingPathComponent(name))
        return try XCTUnwrap(
            Data(base64Encoded: data, options: .ignoreUnknownCharacters),
            "Golden fixture \(name) is not base64."
        )
    }

    private func goldenFixtureString(named name: String) throws -> String {
        let data = try Data(contentsOf: professionalSyncFixtureRoot().appendingPathComponent(name))
        return try XCTUnwrap(
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Golden fixture \(name) is not UTF-8."
        )
    }

    private func coordinatorFixture(
        in temporary: URL,
        targetHasDivergentOriginal: Bool = false,
        automaticPackageProfile: RoomAIRoomPackageProfile? = nil,
        deterministicOwnershipTransactions: Bool = false
    ) async throws -> CoordinatorFixture {
        let sourceProjectRoot = temporary.appendingPathComponent("fixture-source-projects", isDirectory: true)
        let sourceWorkspace = temporary.appendingPathComponent("fixture-source-working-copy", isDirectory: true)
        let archiveURL = temporary.appendingPathComponent("fixture-working-set.zip")
        let sourceTransactionIDGenerator: any RoomProjectTransactionIDGenerating = deterministicOwnershipTransactions
            ? DeterministicRoomProjectTransactionIDGenerator(transactionIDs: ["transaction-001"])
            : UUIDRoomProjectTransactionIDGenerator()
        let sourceProjectStore = LocalRoomProjectStore(
            rootURL: sourceProjectRoot,
            clock: FixedRoomProjectClock(date: recoveryDate),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            ),
            transactionIDGenerator: sourceTransactionIDGenerator
        )
        let savedResult = try await sourceProjectStore.saveDraft(recoveryDraft(), decision: .save)
        let sourceSummary = try XCTUnwrap(savedResult)
        let sourceRevision = try await sourceProjectStore.redesignSourceRevisionBinding(
            projectID: sourceSummary.projectID,
            revisionID: sourceSummary.headRevisionID
        )

        let sourceRedesignRoot = temporary.appendingPathComponent("fixture-source-redesign", isDirectory: true)
        let sourceRedesignStore = LocalRoomRedesignStore(rootURL: sourceRedesignRoot)
        let sourceRedesign = try extensionDocument(binding: sourceRevision)
        try await sourceRedesignStore.save(sourceRedesign, expectedSourceRevision: sourceRevision)
        let sourceConceptRoot = temporary.appendingPathComponent("fixture-source-concepts", isDirectory: true)
        let sourceConceptStore = LocalRoomConceptStore(
            rootURL: sourceConceptRoot,
            sourcePackageRootURL: sourceProjectRoot
        )
        let sourcePackageManifestData: Data?
        let sourceContext: RoomConceptSetValidationContext
        if let automaticPackageProfile {
            let canonicalManifestData = try await canonicalAIRoomPackageManifest(
                sourceRevision: sourceRevision,
                redesign: sourceRedesign,
                profile: automaticPackageProfile,
                packageID: "ai-package-001",
                in: temporary.appendingPathComponent("fixture-ai-package-inputs", isDirectory: true)
            )
            let capability = try RoomConceptValidatedSourcePackage(
                validatedManifestData: canonicalManifestData
            )
            sourcePackageManifestData = canonicalManifestData
            sourceContext = .init(
                expectedSourceRevision: sourceRevision,
                currentCanonicalCameraIDs: sourceRedesign.orientation.canonicalCameras.map(\.cameraID),
                validatedSourceAIRoomPackages: [capability]
            )
            _ = try await sourceConceptStore.importConceptSet(
                automaticConceptImport(
                    sourceRevision: sourceRevision,
                    sourceAIRoomPackage: capability.sourceAIRoomPackage
                ),
                context: sourceContext
            )
        } else {
            sourcePackageManifestData = nil
            sourceContext = conceptContext(binding: sourceRevision)
            for offset in 1...2 {
                _ = try await sourceConceptStore.importConceptSet(
                    conceptImport(
                        conceptSetID: String(format: "concept-set-%03d", offset),
                        attachmentID: String(format: "attachment-%03d", offset),
                        sourceRevision: sourceRevision,
                        importedOffset: TimeInterval(offset * 100)
                    ),
                    context: sourceContext
                )
            }
        }
        let optionalRedesignSnapshot = try await sourceRedesignStore.snapshot(sourceRevision: sourceRevision)
        let redesignSnapshot = try XCTUnwrap(optionalRedesignSnapshot)
        let sourceConceptSnapshot = try await sourceConceptStore.snapshot(context: sourceContext)
        let workingCopy = try await sourceProjectStore.materializeProfessionalWorkingCopy(
            projectID: sourceSummary.projectID,
            expectedHeadRevisionID: sourceSummary.headRevisionID,
            into: sourceWorkspace
        )
        let archive: RoomProfessionalWorkingSetSnapshot
        if let sourcePackageManifestData {
            let transport = try RoomProfessionalConceptTransportSnapshot(
                sourceSnapshot: sourceConceptSnapshot,
                sourcePackageManifestData: [sourcePackageManifestData],
                currentCanonicalCameraIDs: sourceRedesign.orientation.canonicalCameras.map(\.cameraID)
            )
            archive = try await RoomProfessionalWorkingSetArchive.build(
                workingCopy: workingCopy,
                archiveURL: archiveURL,
                companionPreparation: try transport.workingSetCompanionPreparation(
                    additionalCompanions: try redesignSnapshot.workingSetCompanions()
                )
            )
        } else {
            archive = try await RoomProfessionalWorkingSetArchive.build(
                workingCopy: workingCopy,
                archiveURL: archiveURL,
                companions: try redesignSnapshot.workingSetCompanions()
                    + sourceConceptSnapshot.workingSetCompanions()
            )
        }
        let sourceProjectBytes = try fileSnapshot(
            at: sourceProjectRoot.appendingPathComponent(sourceSummary.projectID, isDirectory: true)
        )
        let sourceRedesignBytes = try fileSnapshot(at: sourceRedesignRoot)
        let sourceConceptBytes = try fileSnapshot(at: sourceConceptRoot)

        let recoveredProjectRoot = temporary.appendingPathComponent("fixture-recovered-projects", isDirectory: true)
        let recoveredRedesignRoot = temporary.appendingPathComponent("fixture-recovered-redesign", isDirectory: true)
        let recoveredConceptRoot = temporary.appendingPathComponent("fixture-recovered-concepts", isDirectory: true)
        let recoveryScratchRoot = temporary.appendingPathComponent("fixture-recovery-scratch", isDirectory: true)
        let recoveredProjectStore = LocalRoomProjectStore(
            rootURL: recoveredProjectRoot,
            clock: FixedRoomProjectClock(date: recoveryDate),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        if targetHasDivergentOriginal {
            var divergent = try recoveryDraft()
            divergent.metadata.customName = "Divergent recovered original"
            _ = try await recoveredProjectStore.saveDraft(divergent, decision: .save)
        }
        let recoveredRedesignStore = LocalRoomRedesignStore(rootURL: recoveredRedesignRoot)
        let recoveredConceptStore = LocalRoomConceptStore(
            rootURL: recoveredConceptRoot,
            sourcePackageRootURL: recoveredProjectRoot
        )
        return CoordinatorFixture(
            archiveURL: archiveURL,
            descriptor: archive.descriptor,
            archive: archive,
            sourceSummary: sourceSummary,
            sourceRevision: sourceRevision,
            sourceContext: sourceContext,
            sourceRedesign: sourceRedesign,
            sourceConceptSnapshot: sourceConceptSnapshot,
            sourcePackageManifestData: sourcePackageManifestData,
            sourceProjectRoot: sourceProjectRoot,
            sourceProjectBytes: sourceProjectBytes,
            sourceRedesignRoot: sourceRedesignRoot,
            sourceRedesignBytes: sourceRedesignBytes,
            sourceConceptRoot: sourceConceptRoot,
            sourceConceptBytes: sourceConceptBytes,
            recoveredProjectRoot: recoveredProjectRoot,
            recoveredRedesignRoot: recoveredRedesignRoot,
            recoveredConceptRoot: recoveredConceptRoot,
            recoveryScratchRoot: recoveryScratchRoot,
            recoveredProjectStore: recoveredProjectStore,
            recoveredRedesignStore: recoveredRedesignStore,
            recoveredConceptStore: recoveredConceptStore
        )
    }

    private func forgeWorkingSetReplacingEntry(
        archiveURL: URL,
        descriptor: RoomProfessionalWorkingSetDescriptor,
        replacementPath: String,
        replacementData: Data,
        destinationArchiveURL: URL,
        workspace: URL
    ) async throws -> RoomProfessionalWorkingSetDescriptor {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let extraction = workspace.appendingPathComponent("extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
        _ = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
            archiveURL: archiveURL,
            expectedDescriptor: descriptor,
            into: extraction
        )
        let manifestURL = extraction.appendingPathComponent(
            RoomProfessionalWorkingSetArchive.manifestEntryPath
        )
        let manifestData = try Data(contentsOf: manifestURL)
        var manifest = try RoomProfessionalArchiveSupport.decodeWorkingSetManifest(manifestData)
        let entryIndex = try XCTUnwrap(manifest.entries.firstIndex { $0.path == replacementPath })
        let original = manifest.entries[entryIndex]
        manifest.entries[entryIndex] = try RoomProfessionalWorkingSetEntry(
            path: original.path,
            kind: original.kind,
            mediaType: original.mediaType,
            byteCount: UInt64(replacementData.count),
            sha256: RoomSHA256.hexDigest(of: replacementData)
        )
        let replacementURL = extraction.appendingPathComponent(replacementPath)
        try replacementData.write(to: replacementURL)
        let rewrittenManifestData = try RoomProfessionalSyncCanonicalJSON.encode(manifest)
        try rewrittenManifestData.write(to: manifestURL)
        let inputs = try manifest.entries.map { entry in
            RoomZIPInput(
                sourceURL: extraction.appendingPathComponent(entry.path),
                entryPath: try RoomExportEntryPath(entry.path),
                mediaType: entry.mediaType
            )
        } + [RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(RoomProfessionalWorkingSetArchive.manifestEntryPath),
            mediaType: "application/json"
        )]
        let receipt = try await RoomDeterministicZIP.write(
            inputs: inputs,
            to: destinationArchiveURL
        )
        return try RoomProfessionalWorkingSetDescriptor(
            snapshotID: RoomSHA256.hexDigest(of: rewrittenManifestData),
            projectID: manifest.projectID,
            headRevisionID: manifest.headRevisionID,
            packageDescriptor: manifest.packageDescriptor,
            archiveSHA256: receipt.archiveSHA256,
            archiveByteCount: receipt.archiveByteCount
        )
    }

    private func conceptContext(
        binding: RoomRedesignSourceRevision
    ) -> RoomConceptSetValidationContext {
        .init(
            expectedSourceRevision: binding,
            currentCanonicalCameraIDs: ["canonical-front"]
        )
    }

    private func conceptImport(
        conceptSetID: String,
        attachmentID: String,
        sourceRevision: RoomRedesignSourceRevision,
        importedOffset: TimeInterval
    ) -> RoomConceptSetImport {
        let attachment = RoomConceptSetAttachment(
            attachmentID: attachmentID,
            relativePath: "attachments/\(attachmentID).png",
            sha256: RoomSHA256.hexDigest(of: Self.safePNG),
            byteCount: UInt64(Self.safePNG.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedLooseFile,
            mapping: .unmatched
        )
        return RoomConceptSetImport(
            conceptSet: RoomConceptSet(
                conceptSetID: conceptSetID,
                sourceRevision: sourceRevision,
                request: "A warmer concept for \(conceptSetID).",
                scope: .stage,
                provider: nil,
                sourceAIRoomPackage: nil,
                importProvenance: .init(
                    kind: .looseLocalFile,
                    sourceFilename: "\(conceptSetID).png"
                ),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                importedAt: Date(timeIntervalSince1970: 1_700_000_000 + importedOffset),
                attachments: [attachment],
                comments: [],
                approvalState: .pending,
                archiveState: .active
            ),
            attachments: [
                RoomConceptSetAttachmentBytes(attachmentID: attachmentID, data: Self.safePNG)
            ]
        )
    }

    private func automaticConceptImport(
        sourceRevision: RoomRedesignSourceRevision,
        sourceAIRoomPackage: RoomConceptSourceAIRoomPackage
    ) -> RoomConceptSetImport {
        let attachment = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: Self.safePNG),
            byteCount: UInt64(Self.safePNG.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedPackagedFile,
            mapping: .automatic(cameraID: "canonical-entry")
        )
        return RoomConceptSetImport(
            conceptSet: RoomConceptSet(
                conceptSetID: "concept-set-001",
                sourceRevision: sourceRevision,
                request: "A packaged automatic concept.",
                scope: .stage,
                provider: "Example Provider",
                sourceAIRoomPackage: sourceAIRoomPackage,
                importProvenance: .init(
                    kind: .packagedOutput,
                    sourceFilename: "provider-concepts.zip"
                ),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                importedAt: Date(timeIntervalSince1970: 1_700_000_100),
                attachments: [attachment],
                comments: [],
                approvalState: .pending,
                archiveState: .active
            ),
            attachments: [
                RoomConceptSetAttachmentBytes(attachmentID: attachment.attachmentID, data: Self.safePNG)
            ]
        )
    }

    private func recoveryConceptContext(
        binding: RoomRedesignSourceRevision,
        redesign: RoomLocalRedesignExtensionV2,
        provenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot]
    ) throws -> RoomConceptSetValidationContext {
        .init(
            expectedSourceRevision: binding,
            currentCanonicalCameraIDs: redesign.orientation.canonicalCameras.map(\.cameraID),
            validatedSourceAIRoomPackages: try provenance.map { try $0.validatedSourcePackage() }
        )
    }

    private func canonicalAIRoomPackageManifest(
        sourceRevision: RoomRedesignSourceRevision,
        redesign: RoomLocalRedesignExtensionV2,
        profile: RoomAIRoomPackageProfile,
        packageID: String,
        in inputDirectory: URL
    ) async throws -> Data {
        let readyContext = try RoomAIRoomPackageReadiness.requireEligible(
            sourceRevision: sourceRevision,
            companion: redesign
        )
        let plan = try RoomAIArtifactPlanner.makePlan(
            profile: profile,
            context: readyContext,
            inventory: .init()
        )
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let inputs = try plan.slots.map { slot -> RoomAIArtifactBuildInput in
            let optionalClasses: Set<RoomRedesignArtifactClass> = [
                .selectedReferenceImage, .materials, .qualityReport, .mesh, .texture,
                .rawRGB, .rawDepth, .rawConfidence, .diagnostics,
            ]
            guard !optionalClasses.contains(slot.artifactClass) else {
                return .unavailable(slot: slot, reasonCode: "source-unavailable")
            }
            let pathAndMediaType = try aiPackagePathAndMediaType(for: slot)
            let sourceURL = inputDirectory.appendingPathComponent("\(slot.artifactID).bytes")
            let data = pathAndMediaType.mediaType == "image/png"
                ? Self.safePNG
                : Data("fixture:\(slot.artifactID)".utf8)
            try data.write(to: sourceURL, options: .withoutOverwriting)
            return .included(
                slot: slot,
                sourceURL: sourceURL,
                relativePath: pathAndMediaType.path,
                mediaType: pathAndMediaType.mediaType
            )
        }
        let preparation = try await RoomAIRoomPackageBuilder.prepare(
            packageID: packageID,
            plan: plan,
            inputs: inputs
        )
        let package = try preparation.finalize(
            disclosureReview: RoomDisclosureReview(
                reviewID: "review-001",
                reviewedAt: recoveryDate,
                decision: .approved,
                sourceRevisionID: sourceRevision.revisionID,
                sourceRevisionManifestSHA256: sourceRevision.revisionManifestSHA256,
                reviewedArtifactPlanSHA256: preparation.artifactPlanSHA256,
                reviewedSelectionSHA256: preparation.selectionSHA256,
                preciseGPSExcluded: true,
                rawEvidenceDisclosureAccepted: false
            )
        )
        return try RoomAIRoomPackageBuilder.canonicalManifestData(package)
    }

    private func aiPackagePathAndMediaType(
        for slot: RoomAIArtifactSlot
    ) throws -> (path: String, mediaType: String) {
        switch slot.artifactClass {
        case .normalizedSemantics:
            return ("truth/semantic-model.json", "application/json")
        case .revisionLineage:
            return ("truth/revision-lineage.json", "application/json")
        case .orientation:
            return ("truth/orientation.json", "application/json")
        case .floorPlan:
            return ("derivatives/floor-plan.png", "image/png")
        case .canonicalView:
            let prefix = "canonical-view-"
            guard slot.artifactID.hasPrefix(prefix) else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Canonical test package slot did not identify a camera."
                )
            }
            return (
                "derivatives/canonical-views/\(slot.artifactID.dropFirst(prefix.count)).png",
                "image/png"
            )
        case .roomBrief:
            return ("brief/room-brief.txt", "text/plain")
        case .redesignIntent:
            return ("intent/redesign-intent.json", "application/json")
        case .providerInstructions:
            return ("instructions/\(slot.artifactID).txt", "text/plain")
        case .selectedReferenceImage, .materials, .qualityReport, .mesh, .texture,
             .rawRGB, .rawDepth, .rawConfidence, .diagnostics:
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Optional test package slot unexpectedly required an input."
            )
        case .conceptAttachment, .comments, .worldMap:
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Unsupported test package artifact class."
            )
        }
    }

    private func conceptSetSnapshot(
        from materialization: RoomConceptSetImport
    ) throws -> RoomProfessionalConceptSetSnapshot {
        let concept = materialization.conceptSet
        let canonicalManifestData = try RoomConceptSetCanonicalJSON.encode(concept)
        let bytesByID = Dictionary(
            uniqueKeysWithValues: materialization.attachments.map { ($0.attachmentID, $0.data) }
        )
        let attachments = try concept.attachments.map { declaration in
            guard let data = bytesByID[declaration.attachmentID] else {
                throw RoomProfessionalRecoveryError.invalidSnapshot("Missing test attachment bytes.")
            }
            return try RoomProfessionalConceptAttachmentSnapshot(
                attachmentID: declaration.attachmentID,
                relativePath: declaration.relativePath,
                mediaType: declaration.mediaType,
                data: data,
                byteCount: declaration.byteCount,
                sha256: declaration.sha256
            )
        }
        return try RoomProfessionalConceptSetSnapshot(
            sourceRevision: concept.sourceRevision,
            conceptSetID: concept.conceptSetID,
            canonicalManifestData: canonicalManifestData,
            manifestSHA256: RoomSHA256.hexDigest(of: canonicalManifestData),
            attachments: attachments
        )
    }

    private func fileSnapshot(at root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let fileURL as URL in enumerator {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
            result[relativePath] = try Data(contentsOf: fileURL)
        }
        return result
    }

    private func assertThrowsAsync(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {}
    }

    private static let safePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}
