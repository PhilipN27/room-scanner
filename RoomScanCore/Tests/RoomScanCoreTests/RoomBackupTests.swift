import Foundation
import XCTest
@testable import RoomScanCore

/// Phase-6 contracts are authored on the Windows host but intentionally not
/// executed here: the package requires a Swift toolchain that is unavailable
/// on this host. The Python structural oracle checks that these contracts stay
/// wired to the real Foundation-only backup APIs.
final class RoomBackupTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    func testBackupMaterializationIsFullHistoryDeepCopiedAndDeterministic() async throws {
        let root = temporaryRoot("RoomBackupFullHistory")
        let workspaceOne = root.deletingLastPathComponent().appendingPathComponent("RoomBackupWorkspaceOne-\(UUID().uuidString)")
        let workspaceTwo = root.deletingLastPathComponent().appendingPathComponent("RoomBackupWorkspaceTwo-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspaceOne)
            try? FileManager.default.removeItem(at: workspaceTwo)
        }

        let source = try await makeProject(root: root, revisionIDs: ["revision-001", "revision-002"])
        let sourceBytes = try regularFileSnapshot(root.appendingPathComponent(source.summary.projectID))

        let first = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: "revision-002",
            into: workspaceOne
        )
        let firstSnapshot = try await RoomProjectBackupArchive.build(
            materialization: first,
            archiveURL: workspaceOne.appendingPathComponent("snapshot.zip")
        )
        let second = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: "revision-002",
            into: workspaceTwo
        )
        let secondSnapshot = try await RoomProjectBackupArchive.build(
            materialization: second,
            archiveURL: workspaceTwo.appendingPathComponent("snapshot.zip")
        )

        XCTAssertEqual(firstSnapshot.descriptor.snapshotID, secondSnapshot.descriptor.snapshotID)
        XCTAssertEqual(try Data(contentsOf: firstSnapshot.archiveURL), try Data(contentsOf: secondSnapshot.archiveURL))
        XCTAssertEqual(try regularFileSnapshot(root.appendingPathComponent(source.summary.projectID)), sourceBytes)
        XCTAssertFalse(first.entries.contains { $0.packageRelativePath.value == ".roomscan-ownership.json" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceOne.appendingPathComponent(".roomscan-backup-workspace.json").path))
        XCTAssertTrue(first.entries.contains { $0.packageRelativePath.value == "revisions/revision-001/.roomscan-ownership.json" })
        XCTAssertTrue(first.entries.contains { $0.packageRelativePath.value == "revisions/revision-002/photos/reference-001.png" })
        XCTAssertFalse(try isHardLinked(
            source: root.appendingPathComponent("\(source.summary.projectID)/revisions/revision-002/photos/reference-001.png"),
            copy: workspaceOne.appendingPathComponent(first.entries.first { $0.packageRelativePath.value == "revisions/revision-002/photos/reference-001.png" }!.workspaceRelativePath.value)
        ))
    }

    func testBackupArchiveUsesManifestMappedASCIINamesForUnicodePackageAssets() async throws {
        let root = temporaryRoot("RoomBackupUnicode")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupUnicodeWorkspace-\(UUID().uuidString)")
        let sourceAssetDirectory = root.deletingLastPathComponent().appendingPathComponent("RoomBackupUnicodeSource-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sourceAssetDirectory)
        }
        try FileManager.default.createDirectory(at: sourceAssetDirectory, withIntermediateDirectories: true)
        let photoSource = sourceAssetDirectory.appendingPathComponent("photo source.png")
        try Data("photo-bytes".utf8).write(to: photoSource)
        let relativePhoto = try RoomRelativePath("photos/Reference Caf\u{00e9}.png")
        var draft = makeDraft()
        draft.revision.photos = [
            RoomPhoto(id: "photo-001", createdAt: date, assetRelativePath: relativePhoto, caption: "Unicode path")
        ]
        let store = makeStore(root: root, revisionIDs: ["revision-001"])
        let savedResult = try await store.saveDraft(
            draft,
            decision: .save,
            assets: [RoomAssetInput(sourceURL: photoSource, destination: relativePhoto, scope: .revision)]
        )
        let saved = try XCTUnwrap(savedResult)

        let materialization = try await store.materializeBackupSnapshot(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: workspace
        )
        let mapped = try XCTUnwrap(materialization.entries.first { $0.packageRelativePath.value.hasSuffix("Reference Caf\u{00e9}.png") })
        XCTAssertTrue(mapped.entryPath.value.hasPrefix("package/files/file-"))
        XCTAssertTrue(mapped.entryPath.value.unicodeScalars.allSatisfy { $0.isASCII })
        let snapshot = try await RoomProjectBackupArchive.build(
            materialization: materialization,
            archiveURL: workspace.appendingPathComponent("snapshot.zip")
        )
        XCTAssertTrue(snapshot.manifest.entries.contains { $0.packageRelativePath == relativePhoto.value })
    }

    func testBackupRejectsNoncanonicalIndexedArchivePath() async throws {
        let root = temporaryRoot("RoomBackupNoncanonicalArchivePath")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupNoncanonicalArchivePathWorkspace-\(UUID().uuidString)")
        let recovery = root.deletingLastPathComponent().appendingPathComponent("RoomBackupNoncanonicalArchivePathRecovery-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: recovery)
        }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        var materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: source.summary.headRevisionID,
            into: workspace
        )
        var first = try XCTUnwrap(materialization.entries.first)
        first.entryPath = try RoomBackupArchivePath("package/files/file-9999.bin")
        materialization.entries[0] = first

        do {
            _ = try await RoomProjectBackupArchive.build(
                materialization: materialization,
                archiveURL: workspace.appendingPathComponent("noncanonical.zip")
            )
            XCTFail("Expected noncanonical indexed archive path rejection.")
        } catch let error as RoomBackupError {
            XCTAssertEqual(error, .invalidArchivePath("package/files/file-9999.bin"))
        }

        // The build guard is not the only boundary: a forged archive with a
        // descriptor-valid manifest path must be rejected again by recovery.
        let zipLimits = try RoomBackupLimits().validatedZIPLimits()
        let inputs = try materialization.entries.sorted { $0.entryPath < $1.entryPath }.map { entry in
            RoomZIPInput(
                sourceURL: workspace.appendingPathComponent(entry.workspaceRelativePath.value),
                entryPath: try entry.entryPath.zipEntryPath(),
                mediaType: entry.mediaType
            )
        }
        let digests = try await RoomDeterministicZIP.preflight(inputs: inputs, limits: zipLimits)
        var manifestEntries: [RoomBackupManifestEntry] = []
        for digest in digests {
            let mapped = try XCTUnwrap(materialization.entries.first {
                $0.entryPath.value == digest.entryPath.value
            })
            manifestEntries.append(RoomBackupManifestEntry(
                archivePath: digest.entryPath.value,
                packageRelativePath: mapped.packageRelativePath.value,
                mediaType: digest.mediaType,
                byteCount: digest.byteCount,
                sha256Hex: digest.sha256Hex
            ))
        }
        manifestEntries.sort { $0.archivePath < $1.archivePath }
        let manifest = RoomBackupManifest(
            projectID: materialization.projectID,
            headRevisionID: materialization.headRevisionID,
            projectSchemaVersion: materialization.projectSchemaVersion,
            displayName: materialization.displayName,
            sourceUpdatedAt: materialization.sourceUpdatedAt,
            revisionCount: materialization.revisionCount,
            entries: manifestEntries
        )
        let manifestData = try RoomJSONCoding.makeEncoder().encode(manifest)
        let manifestURL = workspace.appendingPathComponent(RoomProjectBackupArchive.manifestEntryPath)
        try manifestData.write(to: manifestURL, options: [.atomic, .withoutOverwriting])
        let manifestInput = RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(RoomProjectBackupArchive.manifestEntryPath),
            mediaType: "application/json"
        )
        let archiveURL = workspace.appendingPathComponent("forged-noncanonical.zip")
        let receipt = try await RoomDeterministicZIP.write(
            inputs: inputs + [manifestInput],
            to: archiveURL,
            limits: zipLimits
        )
        let descriptor = RoomCloudBackupDescriptor(
            snapshotID: RoomSHA256.hexDigest(of: manifestData),
            projectID: materialization.projectID,
            headRevisionID: materialization.headRevisionID,
            projectSchemaVersion: materialization.projectSchemaVersion,
            displayName: materialization.displayName,
            sourceUpdatedAt: materialization.sourceUpdatedAt,
            revisionCount: materialization.revisionCount,
            fileCount: manifestEntries.count,
            uncompressedByteCount: manifestEntries.reduce(UInt64(0)) { $0 + $1.byteCount },
            manifestSHA256: RoomSHA256.hexDigest(of: manifestData),
            archiveSHA256: receipt.archiveSHA256,
            archiveByteCount: receipt.archiveByteCount
        )
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        do {
            _ = try await RoomProjectBackupArchive.extractAndVerify(
                archiveURL: archiveURL,
                expectedDescriptor: descriptor,
                into: recovery
            )
            XCTFail("Expected recovery to reject a noncanonical indexed archive path.")
        } catch let error as RoomBackupError {
            XCTAssertEqual(error, .invalidArchivePath("package/files/file-9999.bin"))
        }
    }

    func testBackupCanonicalizesSubsecondTimestampAcrossManifestAndDescriptor() async throws {
        let root = temporaryRoot("RoomBackupSubsecondDate")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupSubsecondWorkspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        var materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: source.summary.headRevisionID,
            into: workspace
        )
        materialization.sourceUpdatedAt = Date(timeIntervalSince1970: 1_704_067_200.789)
        let snapshot = try await RoomProjectBackupArchive.build(
            materialization: materialization,
            archiveURL: workspace.appendingPathComponent("snapshot.zip")
        )
        let encodedManifest = try RoomJSONCoding.makeEncoder().encode(snapshot.manifest)
        let decodedManifest = try RoomJSONCoding.makeDecoder().decode(RoomBackupManifest.self, from: encodedManifest)
        XCTAssertEqual(decodedManifest.sourceUpdatedAt, snapshot.descriptor.sourceUpdatedAt)
        XCTAssertNotEqual(decodedManifest.sourceUpdatedAt, materialization.sourceUpdatedAt)
    }

    func testBackupExcludesExportsPendingAndStagingArtifacts() async throws {
        let root = temporaryRoot("RoomBackupExclusions")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupExclusionsWorkspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        let projectURL = root.appendingPathComponent(source.summary.projectID)
        let exportURL = projectURL.appendingPathComponent("revisions/revision-001/exports/ignored.txt")
        let stagingURL = projectURL.appendingPathComponent(".staging-test/ignored.txt")
        let pendingURL = projectURL.appendingPathComponent(".pending-revision.json")
        try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: exportURL)
        try Data("ignored".utf8).write(to: stagingURL)
        try Data("not-a-real-marker".utf8).write(to: pendingURL)

        // The visible pending marker is intentionally malformed. A full backup
        // must fail closed rather than treating it as an owned artifact.
        do {
            _ = try await source.store.materializeBackupSnapshot(
                projectID: source.summary.projectID,
                expectedHeadRevisionID: source.summary.headRevisionID,
                into: workspace
            )
            XCTFail("Expected malformed pending state to be rejected before backup.")
        } catch {
            // Expected: reconciliation validates pending ownership first.
        }
        try FileManager.default.removeItem(at: pendingURL)
        let materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: source.summary.headRevisionID,
            into: workspace
        )
        XCTAssertFalse(materialization.entries.contains { $0.packageRelativePath.value.contains("exports/") })
        XCTAssertFalse(materialization.entries.contains { $0.packageRelativePath.value.contains(".staging-") })
    }

    func testBackupLimitsReserveManifestEntryAndRejectOneMorePackageFile() async throws {
        let root = temporaryRoot("RoomBackupLimits")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupLimitsWorkspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        XCTAssertEqual(RoomBackupLimits.maximumArchiveEntries, 4_096)
        XCTAssertEqual(RoomBackupLimits.maximumPackageEntries, 4_095)
        XCTAssertEqual(RoomBackupLimits().maxPackageEntries, 4_095)
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        let strictStore = LocalRoomProjectStore(
            rootURL: root,
            exportMaterializationLimits: RoomExportMaterializationLimits(),
            backupLimits: RoomBackupLimits(maxPackageEntries: 1, maxFileBytes: 1_024, maxArchiveBytes: 4_096)
        )
        do {
            _ = try await strictStore.materializeBackupSnapshot(
                projectID: source.summary.projectID,
                expectedHeadRevisionID: source.summary.headRevisionID,
                into: workspace
            )
            XCTFail("Expected injected backup package-entry limit rejection.")
        } catch let error as RoomBackupError {
            XCTAssertEqual(error, .entryLimitExceeded)
        }
    }

    func testBackupRejectsInvalidInjectedLimitsWithoutArithmeticOverflow() throws {
        XCTAssertThrowsError(
            try RoomBackupLimits(
                maxPackageEntries: Int.max,
                maxFileBytes: 1,
                maxArchiveBytes: 1
            ).validatedZIPLimits()
        )
        XCTAssertThrowsError(
            try RoomBackupLimits(
                maxPackageEntries: 0,
                maxFileBytes: 0,
                maxArchiveBytes: 1
            ).validatedZIPLimits()
        )
    }

    func testValidatedHistoricalV1WithoutRevisionMarkerRemainsBackupCompatible() async throws {
        let root = temporaryRoot("RoomBackupLegacyV1")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupLegacyV1Workspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        let projectURL = root.appendingPathComponent(source.summary.projectID)
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        var manifest = try RoomJSONCoding.makeDecoder().decode(
            RoomProjectManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        manifest.schemaVersion = RoomProjectSchemaVersion.v1.rawValue
        try RoomJSONCoding.makeEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        let revisionURL = projectURL.appendingPathComponent("revisions/revision-001", isDirectory: true)
        let revisionManifestURL = revisionURL.appendingPathComponent("revision.json")
        var revisionManifest = try RoomJSONCoding.makeDecoder().decode(
            RoomRevisionManifest.self,
            from: Data(contentsOf: revisionManifestURL)
        )
        // A real v1 package predates the explicit v2 strict-evidence field;
        // merely downgrading the project manifest is not compatibility proof.
        revisionManifest.evidenceCompatibility = nil
        revisionManifest.captureEvidence = nil
        try RoomJSONCoding.makeEncoder().encode(revisionManifest).write(
            to: revisionManifestURL,
            options: .atomic
        )
        try FileManager.default.removeItem(at: revisionURL.appendingPathComponent(".roomscan-ownership.json"))

        let materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: source.summary.headRevisionID,
            into: workspace
        )
        XCTAssertFalse(materialization.entries.contains { $0.packageRelativePath.value.hasSuffix(".roomscan-ownership.json") })
        XCTAssertFalse(materialization.entries.contains { $0.packageRelativePath.value == ".roomscan-ownership.json" })
    }

    func testBackupRejectsCaseAliasedReservedRevisionNamespaces() async throws {
        let root = temporaryRoot("RoomBackupCaseAlias")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupCaseAliasWorkspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        let revisionURL = root.appendingPathComponent("\(source.summary.projectID)/revisions/revision-001", isDirectory: true)
        let alias = revisionURL.appendingPathComponent("Exports/should-not-upload.txt")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unowned".utf8).write(to: alias)

        do {
            _ = try await source.store.materializeBackupSnapshot(
                projectID: source.summary.projectID,
                expectedHeadRevisionID: source.summary.headRevisionID,
                into: workspace
            )
            XCTFail("Expected a case-aliased reserved namespace to fail closed.")
        } catch let error as RoomBackupError {
            guard case .invalidPackagePath = error else {
                return XCTFail("Expected invalid package path, got \(error).")
            }
        }
    }

    func testBackupRecoveryRejectsMalformedLocalSignatureBeforeExtraction() async throws {
        let root = temporaryRoot("RoomBackupCorruption")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupCorruptionWorkspace-\(UUID().uuidString)")
        let recoveryWorkspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupRecoveryWorkspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: recoveryWorkspace)
        }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        let materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: source.summary.headRevisionID,
            into: workspace
        )
        let snapshot = try await RoomProjectBackupArchive.build(
            materialization: materialization,
            archiveURL: workspace.appendingPathComponent("snapshot.zip")
        )
        var corrupted = try Data(contentsOf: snapshot.archiveURL)
        corrupted[0] ^= 0x01
        let corruptedURL = workspace.appendingPathComponent("corrupted.zip")
        try corrupted.write(to: corruptedURL, options: .atomic)
        let receiver = makeStore(root: recoveryWorkspace, revisionIDs: ["recovery-001"])
        do {
            _ = try await receiver.prepareRecovery(
                archiveURL: corruptedURL,
                expectedCloudDescriptor: snapshot.descriptor,
                into: recoveryWorkspace.deletingLastPathComponent().appendingPathComponent("RoomBackupRecoveryStage-\(UUID().uuidString)")
            )
            XCTFail("Expected strict ZIP local-signature rejection.")
        } catch {
            // Expected: strict reader rejects a malformed local header.
        }
    }

    func testBackupReaderRejectsIndependentCRCDigestClosureAndNoncanonicalManifestControls() async throws {
        let root = temporaryRoot("RoomBackupReaderControls")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomBackupReaderWorkspace-\(UUID().uuidString)")
        let receiverRoot = temporaryRoot("RoomBackupReaderReceiver")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: receiverRoot)
        }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        let materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: source.summary.headRevisionID,
            into: workspace
        )
        let snapshot = try await RoomProjectBackupArchive.build(
            materialization: materialization,
            archiveURL: workspace.appendingPathComponent("canonical.zip")
        )
        let receiver = makeStore(root: receiverRoot, revisionIDs: ["recovery-001"])

        // CRC is independently checked after a descriptor-valid archive hash:
        // change a payload byte and bind the descriptor to those altered bytes.
        var crcBytes = try Data(contentsOf: snapshot.archiveURL)
        let photoBytes = Data("reference-photo".utf8)
        let payloadRange = try XCTUnwrap(crcBytes.range(of: photoBytes))
        crcBytes[payloadRange.lowerBound] ^= 0x01
        let crcURL = workspace.appendingPathComponent("crc-mutated.zip")
        try crcBytes.write(to: crcURL, options: .atomic)
        var crcDescriptor = snapshot.descriptor
        crcDescriptor.archiveSHA256 = try RoomSHA256.hexDigest(ofFile: crcURL)
        crcDescriptor.archiveByteCount = UInt64(crcBytes.count)
        await assertPreparationRejects(receiver, archiveURL: crcURL, descriptor: crcDescriptor, label: "CRC")

        var digestDescriptor = snapshot.descriptor
        digestDescriptor.snapshotID = String(repeating: "0", count: 64)
        digestDescriptor.manifestSHA256 = digestDescriptor.snapshotID
        await assertPreparationRejects(receiver, archiveURL: snapshot.archiveURL, descriptor: digestDescriptor, label: "manifest digest")

        let extra = workspace.appendingPathComponent("extra.bin")
        try Data("extra".utf8).write(to: extra)
        let closureArchive = workspace.appendingPathComponent("closure-extra.zip")
        let closureReceipt = try await writeBackupArchive(
            materialization: materialization,
            manifestURL: workspace.appendingPathComponent(RoomProjectBackupArchive.manifestEntryPath),
            archiveURL: closureArchive,
            extra: extra
        )
        var closureDescriptor = snapshot.descriptor
        closureDescriptor.archiveSHA256 = closureReceipt.archiveSHA256
        closureDescriptor.archiveByteCount = closureReceipt.archiveByteCount
        await assertPreparationRejects(receiver, archiveURL: closureArchive, descriptor: closureDescriptor, label: "archive closure")

        // The inverse closure control has a manifest reference with no ZIP
        // entry. It proves recovery does not accept a merely-subset archive.
        let missingEntry = try XCTUnwrap(materialization.entries.first).packageRelativePath.value
        let missingArchive = workspace.appendingPathComponent("closure-missing.zip")
        let missingReceipt = try await writeBackupArchive(
            materialization: materialization,
            manifestURL: workspace.appendingPathComponent(RoomProjectBackupArchive.manifestEntryPath),
            archiveURL: missingArchive,
            omittingPackageRelativePath: missingEntry
        )
        var missingDescriptor = snapshot.descriptor
        missingDescriptor.archiveSHA256 = missingReceipt.archiveSHA256
        missingDescriptor.archiveByteCount = missingReceipt.archiveByteCount
        await assertPreparationRejects(receiver, archiveURL: missingArchive, descriptor: missingDescriptor, label: "missing archive closure")

        let manifestURL = workspace.appendingPathComponent(RoomProjectBackupArchive.manifestEntryPath)
        var noncanonical = try Data(contentsOf: manifestURL)
        noncanonical.append(0x0a)
        try noncanonical.write(to: manifestURL, options: .atomic)
        let noncanonicalArchive = workspace.appendingPathComponent("noncanonical.zip")
        let noncanonicalReceipt = try await writeBackupArchive(
            materialization: materialization,
            manifestURL: manifestURL,
            archiveURL: noncanonicalArchive
        )
        var noncanonicalDescriptor = snapshot.descriptor
        noncanonicalDescriptor.snapshotID = RoomSHA256.hexDigest(of: noncanonical)
        noncanonicalDescriptor.manifestSHA256 = noncanonicalDescriptor.snapshotID
        noncanonicalDescriptor.archiveSHA256 = noncanonicalReceipt.archiveSHA256
        noncanonicalDescriptor.archiveByteCount = noncanonicalReceipt.archiveByteCount
        await assertPreparationRejects(receiver, archiveURL: noncanonicalArchive, descriptor: noncanonicalDescriptor, label: "noncanonical manifest")
    }

    func testBackupZIPRejectsSourceMutationBetweenPreflightAndSecondPass() async throws {
        let root = temporaryRoot("RoomBackupSourceMutation")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("frozen-source.bin")
        let archive = root.appendingPathComponent("backup.zip")
        try Data(repeating: 0x41, count: 2_048).write(to: source)
        let input = RoomZIPInput(
            sourceURL: source,
            entryPath: try RoomExportEntryPath("package/files/file-0001.bin"),
            mediaType: "application/octet-stream"
        )

        do {
            _ = try await RoomDeterministicZIP.write(
                inputs: [input],
                to: archive,
                chunkSize: 256,
                faultInjector: BackupSourceMutationFaultInjector(sourceURL: source)
            )
            XCTFail("Expected source mutation after ZIP preflight to fail closed.")
        } catch let error as RoomExportError {
            XCTAssertEqual(error, .sourceChangedAfterPreflight("package/files/file-0001.bin"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testBackupReaderRejectsOversizedManifestBeforeWritingAndPreservesSentinelDestination() async throws {
        let root = temporaryRoot("RoomBackupManifestCap")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("oversized-manifest.json")
        try Data(repeating: 0x61, count: Int(RoomBackupLimits.maximumManifestBytes) + 1).write(to: source)
        let archive = root.appendingPathComponent("oversized.zip")
        let limits = RoomZIPLimits(
            maxEntries: 1,
            maxEntryBytes: RoomBackupLimits.maximumManifestBytes + 1,
            maxArchiveBytes: RoomBackupLimits.maximumManifestBytes + 1_024
        )
        _ = try await RoomDeterministicZIP.write(
            inputs: [RoomZIPInput(
                sourceURL: source,
                entryPath: try RoomExportEntryPath("backup-manifest.json"),
                mediaType: "application/json"
            )],
            to: archive,
            limits: limits
        )

        let extraction = root.appendingPathComponent("extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        do {
            _ = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
                from: archive,
                into: extraction,
                limits: limits,
                maximumByteCountByEntryPath: [
                    "backup-manifest.json": RoomBackupLimits.maximumManifestBytes
                ]
            )
            XCTFail("Expected pre-extraction manifest cap rejection.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: extraction.appendingPathComponent("backup-manifest.json").path
            ))
        }

        let sentinel = extraction.appendingPathComponent("sentinel.txt")
        try Data("preserve".utf8).write(to: sentinel)
        do {
            _ = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
                from: archive,
                into: extraction,
                limits: limits,
                maximumByteCountByEntryPath: [
                    "backup-manifest.json": RoomBackupLimits.maximumManifestBytes
                ]
            )
            XCTFail("Expected nonempty extraction destination rejection.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        }
    }

    func testPreparedRecoveryCanBeDiscardedWithoutPromotingAndTrueV1RecoversExactly() async throws {
        let sourceRoot = temporaryRoot("RoomBackupDiscardAndV1Source")
        let workspace = sourceRoot.deletingLastPathComponent().appendingPathComponent("RoomBackupDiscardAndV1Workspace-\(UUID().uuidString)")
        let targetRoot = temporaryRoot("RoomBackupDiscardAndV1Target")
        let recoveryWorkspace = targetRoot.deletingLastPathComponent().appendingPathComponent("RoomBackupDiscardAndV1Recovery-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: targetRoot)
            try? FileManager.default.removeItem(at: recoveryWorkspace)
        }
        let source = try await makeProject(root: sourceRoot, revisionIDs: ["revision-001"])
        let projectURL = sourceRoot.appendingPathComponent(source.summary.projectID)
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        var projectManifest = try RoomJSONCoding.makeDecoder().decode(RoomProjectManifest.self, from: Data(contentsOf: manifestURL))
        projectManifest.schemaVersion = RoomProjectSchemaVersion.v1.rawValue
        try RoomJSONCoding.makeEncoder().encode(projectManifest).write(to: manifestURL, options: .atomic)
        let revisionURL = projectURL.appendingPathComponent("revisions/revision-001", isDirectory: true)
        let revisionManifestURL = revisionURL.appendingPathComponent("revision.json")
        var revisionManifest = try RoomJSONCoding.makeDecoder().decode(RoomRevisionManifest.self, from: Data(contentsOf: revisionManifestURL))
        revisionManifest.evidenceCompatibility = nil
        revisionManifest.captureEvidence = nil
        try RoomJSONCoding.makeEncoder().encode(revisionManifest).write(to: revisionManifestURL, options: .atomic)
        try FileManager.default.removeItem(at: revisionURL.appendingPathComponent(".roomscan-ownership.json"))

        let materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: source.summary.headRevisionID,
            into: workspace
        )
        let snapshot = try await RoomProjectBackupArchive.build(
            materialization: materialization,
            archiveURL: workspace.appendingPathComponent("v1.zip")
        )
        let target = makeStore(root: targetRoot, revisionIDs: ["target-001"])
        let preparation = try await target.prepareRecovery(
            archiveURL: snapshot.archiveURL,
            expectedCloudDescriptor: snapshot.descriptor,
            into: recoveryWorkspace
        )
        try await target.discardPreparedRecovery(preparation)
        let afterDiscard = try await target.listSummaries(includeArchived: true)
        XCTAssertTrue(afterDiscard.isEmpty)

        let exactPreparation = try await target.prepareRecovery(
            archiveURL: snapshot.archiveURL,
            expectedCloudDescriptor: snapshot.descriptor,
            into: recoveryWorkspace
        )
        let result = try await target.commitPreparedRecovery(exactPreparation, conflictPolicy: .failIfDivergent)
        guard case .restored = result else { return XCTFail("Expected exact v1 restore.") }
        let restored = try await target.load(projectID: source.summary.projectID)
        XCTAssertEqual(restored.manifest.schemaVersion, RoomProjectSchemaVersion.v1.rawValue)
        XCTAssertNil(restored.revisions[0].manifest.evidenceCompatibility)
    }

    func testExactRecoveryNoOpConflictAndRecoverAsCopyRewriteAllIdentifiers() async throws {
        let sourceRoot = temporaryRoot("RoomBackupSource")
        let backupWorkspace = sourceRoot.deletingLastPathComponent().appendingPathComponent("RoomBackupSourceWorkspace-\(UUID().uuidString)")
        let targetRoot = temporaryRoot("RoomBackupTarget")
        let recoveryWorkspace = targetRoot.deletingLastPathComponent().appendingPathComponent("RoomBackupRecoveryWorkspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: backupWorkspace)
            try? FileManager.default.removeItem(at: targetRoot)
            try? FileManager.default.removeItem(at: recoveryWorkspace)
        }
        let source = try await makeProject(root: sourceRoot, revisionIDs: ["revision-001", "revision-002"])
        let materialization = try await source.store.materializeBackupSnapshot(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: "revision-002",
            into: backupWorkspace
        )
        let snapshot = try await RoomProjectBackupArchive.build(
            materialization: materialization,
            archiveURL: backupWorkspace.appendingPathComponent("snapshot.zip")
        )

        let targetGenerator = DeterministicRoomProjectIDGenerator(
            projectIDs: ["recovered-copy-001"],
            revisionIDs: []
        )
        let target = LocalRoomProjectStore(rootURL: targetRoot, idGenerator: targetGenerator)
        let stage = recoveryWorkspace.appendingPathComponent("first", isDirectory: true)
        let preparation = try await target.prepareRecovery(
            archiveURL: snapshot.archiveURL,
            expectedCloudDescriptor: snapshot.descriptor,
            into: stage
        )
        let restored = try await target.commitPreparedRecovery(
            preparation,
            conflictPolicy: .failIfDivergent
        )
        guard case let .restored(summary) = restored else {
            return XCTFail("Expected an exact atomic restore.")
        }
        XCTAssertEqual(summary.projectID, source.summary.projectID)
        let restoredPackage = try await target.load(projectID: source.summary.projectID)
        XCTAssertEqual(restoredPackage.manifest.revisionIDs, ["revision-001", "revision-002"])

        let noOpPreparation = try await target.prepareRecovery(
            archiveURL: snapshot.archiveURL,
            expectedCloudDescriptor: snapshot.descriptor,
            into: recoveryWorkspace.appendingPathComponent("noop", isDirectory: true)
        )
        let noOp = try await target.commitPreparedRecovery(noOpPreparation, conflictPolicy: .failIfDivergent)
        XCTAssertEqual(noOp, .noOp)

        var divergentPayload = try XCTUnwrap(restoredPackage.revisions.last).payload
        divergentPayload.semanticSnapshot.objectElements[0].label = "Local divergence"
        _ = try await target.commitEditRevision(
            projectID: source.summary.projectID,
            expectedHeadRevisionID: "revision-002",
            payload: divergentPayload,
            newRevisionID: "revision-local-003"
        )
        let conflictPreparation = try await target.prepareRecovery(
            archiveURL: snapshot.archiveURL,
            expectedCloudDescriptor: snapshot.descriptor,
            into: recoveryWorkspace.appendingPathComponent("conflict", isDirectory: true)
        )
        do {
            _ = try await target.commitPreparedRecovery(conflictPreparation, conflictPolicy: .failIfDivergent)
            XCTFail("Expected divergent recovery to fail closed without an explicit copy choice.")
        } catch let error as RoomBackupError {
            XCTAssertEqual(error, .recoveryConflict(source.summary.projectID))
        }
        let copy = try await target.commitPreparedRecovery(
            conflictPreparation,
            conflictPolicy: .recoverAsCopy
        )
        guard case let .recoveredCopy(copySummary) = copy else {
            return XCTFail("Expected explicit recover-as-copy result.")
        }
        XCTAssertEqual(copySummary.projectID, "recovered-copy-001")
        XCTAssertTrue(copySummary.customName.hasSuffix(" (Recovered Copy)"))
        let copyPackage = try await target.load(projectID: copySummary.projectID)
        XCTAssertEqual(copyPackage.manifest.projectID, copySummary.projectID)
        XCTAssertEqual(copyPackage.revisions.map(\.manifest.projectID), [copySummary.projectID, copySummary.projectID])
        XCTAssertEqual(copyPackage.revisions.map(\.manifest.revisionID), ["revision-001", "revision-002"])
        let copyProjectURL = targetRoot.appendingPathComponent(copySummary.projectID, isDirectory: true)
        let copiedMetadata = try RoomJSONCoding.makeDecoder().decode(
            RoomMetadata.self,
            from: Data(contentsOf: copyProjectURL.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(copiedMetadata.projectID, copySummary.projectID)
        for revisionID in ["revision-001", "revision-002"] {
            let revisionURL = copyProjectURL.appendingPathComponent("revisions/\(revisionID)", isDirectory: true)
            let revision = try RoomJSONCoding.makeDecoder().decode(
                RoomRevisionManifest.self,
                from: Data(contentsOf: revisionURL.appendingPathComponent("revision.json"))
            )
            let semantic = try RoomJSONCoding.makeDecoder().decode(
                RoomSemanticSnapshot.self,
                from: Data(contentsOf: revisionURL.appendingPathComponent("semantic-model.json"))
            )
            let annotations = try RoomJSONCoding.makeDecoder().decode(
                RoomAnnotationsDocument.self,
                from: Data(contentsOf: revisionURL.appendingPathComponent("annotations.json"))
            )
            let measurements = try RoomJSONCoding.makeDecoder().decode(
                RoomMeasurementsDocument.self,
                from: Data(contentsOf: revisionURL.appendingPathComponent("measurements.json"))
            )
            let photos = try RoomJSONCoding.makeDecoder().decode(
                RoomPhotosDocument.self,
                from: Data(contentsOf: revisionURL.appendingPathComponent("photos.json"))
            )
            let ownership = try RoomJSONCoding.makeDecoder().decode(
                RoomRevisionOwnershipRecord.self,
                from: Data(contentsOf: revisionURL.appendingPathComponent(".roomscan-ownership.json"))
            )
            XCTAssertEqual(revision.projectID, copySummary.projectID)
            XCTAssertEqual(semantic.projectID, copySummary.projectID)
            XCTAssertEqual(annotations.projectID, copySummary.projectID)
            XCTAssertEqual(measurements.projectID, copySummary.projectID)
            XCTAssertEqual(photos.projectID, copySummary.projectID)
            XCTAssertEqual(ownership.projectID, copySummary.projectID)
        }
    }

    func testBackupRejectsStaleHeadDestinationInsideRootAndMissingV2RevisionOwnership() async throws {
        let root = temporaryRoot("RoomBackupUnsafe")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeProject(root: root, revisionIDs: ["revision-001"])
        let destinationInsideRoot = root.appendingPathComponent("backup-workspace")
        do {
            _ = try await source.store.materializeBackupSnapshot(
                projectID: source.summary.projectID,
                expectedHeadRevisionID: "revision-stale",
                into: root.deletingLastPathComponent().appendingPathComponent("RoomBackupStale-\(UUID().uuidString)")
            )
            XCTFail("Expected stale-head rejection.")
        } catch let error as RoomBackupError {
            guard case .staleHead = error else { return XCTFail("Expected backup stale head error.") }
        }
        do {
            _ = try await source.store.materializeBackupSnapshot(
                projectID: source.summary.projectID,
                expectedHeadRevisionID: source.summary.headRevisionID,
                into: destinationInsideRoot
            )
            XCTFail("Expected destination-inside-root rejection.")
        } catch let error as RoomBackupError {
            XCTAssertEqual(error, .destinationInsideProjectRoot)
        }
        // There is deliberately no live project ownership document. The backup
        // envelope marker is workspace-only; a missing project marker remains
        // compatible. A missing v2 revision ownership record fails closed.
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(source.summary.projectID)/revisions/revision-001/.roomscan-ownership.json"))
        do {
            _ = try await source.store.materializeBackupSnapshot(
                projectID: source.summary.projectID,
                expectedHeadRevisionID: source.summary.headRevisionID,
                into: root.deletingLastPathComponent().appendingPathComponent("RoomBackupMarkerless-\(UUID().uuidString)")
            )
            XCTFail("Expected a v2 package missing revision ownership to fail closed.")
        } catch let error as RoomBackupError {
            guard case .missingOwnershipMarker = error else { return XCTFail("Expected missing ownership marker error.") }
        }
    }

    // MARK: - Fixtures

    private func assertPreparationRejects(
        _ store: LocalRoomProjectStore,
        archiveURL: URL,
        descriptor: RoomCloudBackupDescriptor,
        label: String
    ) async {
        let workspace = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("rejection-stage-\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await store.prepareRecovery(
                archiveURL: archiveURL,
                expectedCloudDescriptor: descriptor,
                into: workspace
            )
            XCTFail("Expected \(label) backup rejection.")
        } catch {
            // Each control binds the descriptor to the altered archive where
            // needed, so this reaches the strict reader rather than only a
            // superficial source-file precondition.
        }
    }

    private func writeBackupArchive(
        materialization: RoomBackupMaterialization,
        manifestURL: URL,
        archiveURL: URL,
        extra: URL? = nil,
        omittingPackageRelativePath: String? = nil
    ) async throws -> RoomZIPArchiveReceipt {
        var inputs = try materialization.entries
            .filter { $0.packageRelativePath.value != omittingPackageRelativePath }
            .map { entry in
            RoomZIPInput(
                sourceURL: materialization.workspaceURL.appendingPathComponent(entry.workspaceRelativePath.value),
                entryPath: try entry.entryPath.zipEntryPath(),
                mediaType: entry.mediaType
            )
        }
        inputs.append(RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(RoomProjectBackupArchive.manifestEntryPath),
            mediaType: "application/json"
        ))
        if let extra {
            inputs.append(RoomZIPInput(
                sourceURL: extra,
                entryPath: try RoomExportEntryPath("package/extra-control.bin"),
                mediaType: "application/octet-stream"
            ))
        }
        return try await RoomDeterministicZIP.write(
            inputs: inputs,
            to: archiveURL,
            limits: try RoomBackupLimits().validatedZIPLimits()
        )
    }

    private func makeProject(
        root: URL,
        revisionIDs: [String]
    ) async throws -> (store: LocalRoomProjectStore, summary: RoomProjectSummary) {
        let store = makeStore(root: root, revisionIDs: revisionIDs)
        let sourceDirectory = root.deletingLastPathComponent().appendingPathComponent("RoomBackupAssetSources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let thumbnail = sourceDirectory.appendingPathComponent("thumbnail.png")
        let photo = sourceDirectory.appendingPathComponent("reference.png")
        try Data([137, 80, 78, 71, 13, 10, 26, 10]).write(to: thumbnail)
        try Data("reference-photo".utf8).write(to: photo)
        var draft = makeDraft()
        draft.metadata.thumbnailRelativePath = try RoomRelativePath("thumbnails/thumbnail.png")
        draft.revision.photos = [
            RoomPhoto(id: "photo-001", createdAt: date, assetRelativePath: try RoomRelativePath("photos/reference-001.png"), caption: "Reference")
        ]
        let savedResult = try await store.saveDraft(
            draft,
            decision: .save,
            assets: [
                RoomAssetInput(sourceURL: thumbnail, destination: try RoomRelativePath("thumbnails/thumbnail.png"), scope: .project),
                RoomAssetInput(sourceURL: photo, destination: try RoomRelativePath("photos/reference-001.png"), scope: .revision),
            ]
        )
        let summary = try XCTUnwrap(savedResult)
        if revisionIDs.count > 1 {
            let loaded = try await store.load(projectID: summary.projectID)
            var payload = try XCTUnwrap(loaded.revisions.last).payload
            payload.semanticSnapshot.objectElements[0].label = "Backup second revision"
            _ = try await store.commitEditRevision(
                projectID: summary.projectID,
                expectedHeadRevisionID: summary.headRevisionID,
                payload: payload,
                newRevisionID: revisionIDs[1]
            )
            let updated = try await store.load(projectID: summary.projectID)
            return (store, RoomProjectSummary(
                projectID: summary.projectID,
                customName: updated.metadata.customName,
                captureDate: updated.metadata.captureDate,
                lastRevisedDate: updated.effectiveLastRevisedDate,
                manualLocation: updated.metadata.manualLocation,
                tags: updated.metadata.tags,
                thumbnailRelativePath: updated.metadata.thumbnailRelativePath,
                archived: updated.metadata.archived,
                headRevisionID: updated.manifest.headRevisionID
            ))
        }
        return (store, summary)
    }

    private func makeStore(root: URL, revisionIDs: [String]) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["backup-project-001"],
                revisionIDs: revisionIDs
            )
        )
    }

    private func makeDraft() -> RoomDraft {
        let snapshot = RoomSemanticSnapshot(
            projectID: "draft-project",
            revisionID: "draft-revision",
            units: "meters",
            accuracyDisclaimer: "Measurements are estimates, not survey-grade evidence.",
            structuralElements: [
                RoomSemanticElement(
                    id: "structure-floor-001",
                    kind: "floor",
                    label: "Main floor",
                    dimensionsMeters: RoomDimensions(width: 4, height: 0, depth: 5),
                    mobility: .structural
                ),
            ],
            objectElements: [
                RoomSemanticElement(
                    id: "object-desk-001",
                    kind: "desk",
                    label: "Desk",
                    dimensionsMeters: RoomDimensions(width: 1, height: 1, depth: 1),
                    mobility: .fixed
                ),
            ]
        )
        return RoomDraft(
            metadata: RoomMetadata(
                projectID: "draft-project",
                customName: "Backup room",
                captureDate: date,
                lastRevisedDate: date,
                manualLocation: "Lab",
                optionalGPS: nil,
                notes: "",
                tags: ["backup"],
                thumbnailRelativePath: nil,
                archived: false
            ),
            revision: RoomRevisionPayload(
                semanticSnapshot: snapshot,
                annotations: [],
                measurements: [],
                photos: []
            )
        )
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func regularFileSnapshot(_ root: URL) throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        )
        var snapshot: [String: Data] = [:]
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            snapshot[relative] = try Data(contentsOf: url)
        }
        return snapshot
    }

    private func isHardLinked(source: URL, copy: URL) throws -> Bool {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let copyAttributes = try FileManager.default.attributesOfItem(atPath: copy.path)
        let sourceNumber = sourceAttributes[.systemFileNumber] as? NSNumber
        let copyNumber = copyAttributes[.systemFileNumber] as? NSNumber
        return sourceNumber != nil && sourceNumber == copyNumber
    }
}

private final class BackupSourceMutationFaultInjector: RoomZIPFaultInjecting, @unchecked Sendable {
    private let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func throwIfNeeded(at point: RoomZIPWritingFaultPoint) throws {
        guard point == .afterPreflight else { return }
        try Data(repeating: 0x42, count: 2_048).write(to: sourceURL, options: .atomic)
    }
}
