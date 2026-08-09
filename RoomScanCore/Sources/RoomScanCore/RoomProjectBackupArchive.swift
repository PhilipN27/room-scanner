import Foundation

/// Builds and reads the immutable Phase-6 full-project archive envelope. It
/// uses the existing Foundation-only ZIP32 STORE implementation, but defines a
/// separate manifest and strict package-path mapping so it cannot be confused
/// with the bounded head-revision export.
public enum RoomProjectBackupArchive {
    /// Fixed app-owned path for the one manifest entry. It is intentionally
    /// reserved before any backup ZIP is built.
    public static let manifestEntryPath = "backup-manifest.json"

    public static func build(
        materialization: RoomBackupMaterialization,
        archiveURL: URL,
        limits: RoomBackupLimits = RoomBackupLimits()
    ) async throws -> RoomBackupSnapshot {
        let workspace = materialization.workspaceURL.standardizedFileURL
        try validateWorkspace(workspace)
        try validateMaterialization(materialization, workspace: workspace, limits: limits)
        let zipLimits = try limits.validatedZIPLimits()
        let canonicalUpdatedAt = try canonicalDate(materialization.sourceUpdatedAt)

        let inputs = try materialization.entries
            .sorted { $0.entryPath < $1.entryPath }
            .map { entry in
                RoomZIPInput(
                    sourceURL: workspace.appendingPathComponent(entry.workspaceRelativePath.value),
                    entryPath: try entry.entryPath.zipEntryPath(),
                    mediaType: entry.mediaType
                )
            }
        let packageDigests: [RoomZIPEntryDigest]
        do {
            packageDigests = try await RoomDeterministicZIP.preflight(
                inputs: inputs,
                limits: zipLimits
            )
        } catch {
            throw backupError(error)
        }
        let manifestEntries = try makeManifestEntries(
            materialization: materialization,
            digests: packageDigests
        )
        let manifest = RoomBackupManifest(
            projectID: materialization.projectID,
            headRevisionID: materialization.headRevisionID,
            projectSchemaVersion: materialization.projectSchemaVersion,
            displayName: materialization.displayName,
            sourceUpdatedAt: canonicalUpdatedAt,
            revisionCount: materialization.revisionCount,
            entries: manifestEntries
        )
        let manifestURL = workspace.appendingPathComponent(Self.manifestEntryPath)
        guard !pathExists(manifestURL), !isSymbolicLink(manifestURL) else {
            throw RoomBackupError.destinationAlreadyExists(manifestURL.path)
        }
        let manifestData: Data
        do {
            manifestData = try RoomJSONCoding.makeEncoder().encode(manifest)
            try RoomAtomicFileWriter.writeNewFile(manifestData, to: manifestURL)
        } catch {
            throw RoomBackupError.storageFailure("Unable to write backup-manifest.json.")
        }

        let manifestDigest = RoomSHA256.hexDigest(of: manifestData)
        let manifestInput = RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(Self.manifestEntryPath),
            mediaType: "application/json"
        )
        let manifestDigests: [RoomZIPEntryDigest]
        do {
            manifestDigests = try await RoomDeterministicZIP.preflight(
                inputs: [manifestInput],
                limits: zipLimits
            )
        } catch {
            throw backupError(error)
        }
        var finalInputs = inputs
        finalInputs.append(manifestInput)
        let finalDigests = (packageDigests + manifestDigests).sorted {
            $0.entryPath < $1.entryPath
        }
        let receipt: RoomZIPArchiveReceipt
        do {
            receipt = try await RoomDeterministicZIP.write(
                inputs: finalInputs,
                to: archiveURL,
                limits: zipLimits,
                expectedDigests: finalDigests
            )
        } catch {
            throw backupError(error)
        }
        let uncompressedByteCount = try checkedSum(
            manifestEntries.map(\.byteCount),
            cap: limits.maxArchiveBytes
        )
        let descriptor = RoomCloudBackupDescriptor(
            snapshotID: manifestDigest,
            projectID: materialization.projectID,
            headRevisionID: materialization.headRevisionID,
            projectSchemaVersion: materialization.projectSchemaVersion,
            displayName: materialization.displayName,
            sourceUpdatedAt: canonicalUpdatedAt,
            revisionCount: materialization.revisionCount,
            fileCount: manifestEntries.count,
            uncompressedByteCount: uncompressedByteCount,
            manifestSHA256: manifestDigest,
            archiveSHA256: receipt.archiveSHA256,
            archiveByteCount: receipt.archiveByteCount
        )
        try validate(descriptor: descriptor)
        return RoomBackupSnapshot(
            archiveURL: archiveURL,
            manifest: manifest,
            descriptor: descriptor
        )
    }

    /// Strictly verifies then extracts into an already-owned empty directory.
    /// Stored archive names are app-owned ASCII names and never become paths
    /// outside this stage; package-relative restoration happens only after the
    /// manifest closure has been checked.
    public static func extractAndVerify(
        archiveURL: URL,
        expectedDescriptor: RoomCloudBackupDescriptor,
        into destinationURL: URL,
        limits: RoomBackupLimits = RoomBackupLimits()
    ) async throws -> RoomBackupManifest {
        try validate(descriptor: expectedDescriptor)
        let zipLimits = try limits.validatedZIPLimits()
        let archiveAttributes: [FileAttributeKey: Any]
        do {
            archiveAttributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        } catch {
            throw RoomBackupError.zipStructureInvalid("Backup archive is unavailable.")
        }
        guard
            archiveAttributes[.type] as? FileAttributeType == .typeRegular,
            let archiveSize = archiveAttributes[.size] as? NSNumber,
            archiveSize.int64Value >= 0,
            UInt64(archiveSize.int64Value) <= limits.maxArchiveBytes,
            !isSymbolicLink(archiveURL)
        else {
            throw RoomBackupError.zipStructureInvalid("Backup archive is not a bounded regular file.")
        }
        let actualArchiveDigest: String
        do {
            actualArchiveDigest = try RoomSHA256.hexDigest(ofFile: archiveURL)
        } catch {
            throw RoomBackupError.zipStructureInvalid("Backup archive cannot be hashed.")
        }
        guard
            actualArchiveDigest == expectedDescriptor.archiveSHA256,
            UInt64(archiveSize.int64Value) == expectedDescriptor.archiveByteCount
        else {
            throw RoomBackupError.descriptorMismatch("Archive digest or byte count does not match the cloud descriptor.")
        }

        let extracted: [RoomZIPEntryDigest]
        do {
            extracted = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
                from: archiveURL,
                into: destinationURL,
                limits: zipLimits,
                maximumByteCountByEntryPath: [
                    Self.manifestEntryPath: RoomBackupLimits.maximumManifestBytes
                ]
            )
        } catch {
            throw backupError(error)
        }
        guard extracted.count <= RoomBackupLimits.maximumArchiveEntries else {
            throw RoomBackupError.entryLimitExceeded
        }
        let manifestURL = destinationURL.appendingPathComponent(Self.manifestEntryPath)
        let manifestData: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
            guard let manifestSize = attributes[.size] as? NSNumber,
                  manifestSize.int64Value >= 0,
                  UInt64(manifestSize.int64Value) <= RoomBackupLimits.maximumManifestBytes
            else {
                throw RoomBackupError.invalidBackupManifest("backup-manifest.json exceeds the bounded manifest cap.")
            }
            manifestData = try Data(contentsOf: manifestURL)
        } catch let error as RoomBackupError {
            throw error
        } catch {
            throw RoomBackupError.invalidBackupManifest("backup-manifest.json is missing.")
        }
        let manifestDigest = RoomSHA256.hexDigest(of: manifestData)
        guard
            manifestDigest == expectedDescriptor.snapshotID,
            manifestDigest == expectedDescriptor.manifestSHA256
        else {
            throw RoomBackupError.descriptorMismatch("Backup manifest digest does not match the cloud descriptor.")
        }
        let manifest: RoomBackupManifest
        do {
            manifest = try RoomJSONCoding.makeDecoder().decode(RoomBackupManifest.self, from: manifestData)
        } catch {
            throw RoomBackupError.invalidBackupManifest("backup-manifest.json cannot be decoded.")
        }
        do {
            guard try RoomJSONCoding.makeEncoder().encode(manifest) == manifestData else {
                throw RoomBackupError.invalidBackupManifest(
                    "backup-manifest.json is not the canonical signed representation."
                )
            }
        } catch let error as RoomBackupError {
            throw error
        } catch {
            throw RoomBackupError.invalidBackupManifest("backup-manifest.json cannot be canonicalized.")
        }
        try validate(manifest: manifest, extracted: extracted, descriptor: expectedDescriptor, limits: limits)
        return manifest
    }

    public static func validate(
        descriptor: RoomCloudBackupDescriptor
    ) throws {
        guard
            descriptor.schemaVersion == RoomCloudBackupDescriptor.schemaVersion,
            descriptor.archiveFormat == RoomCloudBackupDescriptor.archiveFormat,
            descriptor.complete,
            isLowercaseSHA256(descriptor.snapshotID),
            descriptor.snapshotID == descriptor.manifestSHA256,
            isLowercaseSHA256(descriptor.archiveSHA256),
            RoomPathValidation.isSafeStableIdentifier(descriptor.projectID),
            RoomPathValidation.isSafeStableIdentifier(descriptor.headRevisionID),
            !descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            descriptor.displayName.utf8.count <= 240,
            descriptor.displayName.rangeOfCharacter(from: .controlCharacters) == nil,
            descriptor.fileCount > 0,
            descriptor.fileCount <= RoomBackupLimits.maximumPackageEntries,
            descriptor.revisionCount > 0,
            descriptor.archiveByteCount > 0,
            descriptor.archiveByteCount <= RoomBackupLimits.maximumArchiveBytes,
            descriptor.uncompressedByteCount > 0,
            descriptor.uncompressedByteCount <= RoomBackupLimits.maximumArchiveBytes,
            RoomProjectSchemaVersion(rawValue: descriptor.projectSchemaVersion) != nil
        else {
            throw RoomBackupError.descriptorMismatch("Backup descriptor is incomplete or inconsistent.")
        }
    }

    private static func validateMaterialization(
        _ materialization: RoomBackupMaterialization,
        workspace: URL,
        limits: RoomBackupLimits
    ) throws {
        guard
            materialization.entries.count <= limits.maxPackageEntries,
            materialization.entries.count <= RoomBackupLimits.maximumPackageEntries,
            materialization.revisionCount > 0,
            RoomPathValidation.isSafeStableIdentifier(materialization.projectID),
            RoomPathValidation.isSafeStableIdentifier(materialization.headRevisionID)
        else {
            throw RoomBackupError.entryLimitExceeded
        }
        try validateCanonicalArchiveMapping(
            materialization.entries.map { ($0.entryPath, $0.packageRelativePath) }
        )
        var archiveNames = Set<String>()
        var packageNames = Set<String>()
        var total: UInt64 = 0
        for entry in materialization.entries {
            guard entry.entryPath.value.hasPrefix("package/") else {
                throw RoomBackupError.invalidArchivePath(entry.entryPath.value)
            }
            let archiveKey = entry.entryPath.value.lowercased()
            guard archiveNames.insert(archiveKey).inserted else {
                throw RoomBackupError.duplicatePath(entry.entryPath.value)
            }
            let packageKey = normalizedPackageCollisionKey(entry.packageRelativePath.value)
            guard packageNames.insert(packageKey).inserted else {
                throw RoomBackupError.duplicatePath(entry.packageRelativePath.value)
            }
            let sourceURL = workspace.appendingPathComponent(entry.workspaceRelativePath.value)
            try validateContainedRegularFile(sourceURL, workspace: workspace)
            let size = try fileSize(sourceURL)
            guard size <= limits.maxFileBytes else {
                throw RoomBackupError.sizeLimitExceeded(entry.packageRelativePath.value)
            }
            total = try checkedAdding(total, size, cap: limits.maxArchiveBytes)
        }
        guard total <= limits.maxArchiveBytes else {
            throw RoomBackupError.archiveLimitExceeded
        }
    }

    private static func makeManifestEntries(
        materialization: RoomBackupMaterialization,
        digests: [RoomZIPEntryDigest]
    ) throws -> [RoomBackupManifestEntry] {
        var byArchivePath: [String: RoomBackupMaterializationEntry] = [:]
        for materialized in materialization.entries {
            guard byArchivePath[materialized.entryPath.value] == nil else {
                throw RoomBackupError.duplicatePath(materialized.entryPath.value)
            }
            byArchivePath[materialized.entryPath.value] = materialized
        }
        var entries: [RoomBackupManifestEntry] = []
        for digest in digests {
            guard let materialized = byArchivePath[digest.entryPath.value] else {
                throw RoomBackupError.invalidBackupManifest("Preflight entry lacks a package mapping.")
            }
            entries.append(RoomBackupManifestEntry(
                archivePath: digest.entryPath.value,
                packageRelativePath: materialized.packageRelativePath.value,
                mediaType: digest.mediaType,
                byteCount: digest.byteCount,
                sha256Hex: digest.sha256Hex
            ))
        }
        return entries.sorted { $0.archivePath < $1.archivePath }
    }

    private static func validate(
        manifest: RoomBackupManifest,
        extracted: [RoomZIPEntryDigest],
        descriptor: RoomCloudBackupDescriptor,
        limits: RoomBackupLimits
    ) throws {
        guard
            manifest.formatVersion == RoomBackupManifest.formatVersion,
            manifest.integrityScope == RoomBackupManifest.integrityScope,
            manifest.projectID == descriptor.projectID,
            manifest.headRevisionID == descriptor.headRevisionID,
            manifest.projectSchemaVersion == descriptor.projectSchemaVersion,
            manifest.displayName == descriptor.displayName,
            manifest.sourceUpdatedAt == descriptor.sourceUpdatedAt,
            manifest.revisionCount == descriptor.revisionCount,
            manifest.entries.count == descriptor.fileCount,
            manifest.entries.count <= limits.maxPackageEntries,
            manifest.entries.count <= RoomBackupLimits.maximumPackageEntries
        else {
            throw RoomBackupError.invalidBackupManifest("Backup manifest does not match its descriptor.")
        }
        var archivePaths = Set<String>()
        var packagePaths = Set<String>()
        var archiveMapping: [(RoomBackupArchivePath, RoomBackupPackagePath)] = []
        var manifestTotal: UInt64 = 0
        for entry in manifest.entries {
            let archivePath = try RoomBackupArchivePath(entry.archivePath)
            let packagePath = try RoomBackupPackagePath(entry.packageRelativePath)
            guard archivePath.value.hasPrefix("package/"),
                  !entry.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isLowercaseSHA256(entry.sha256Hex),
                  archivePaths.insert(archivePath.value.lowercased()).inserted,
                  packagePaths.insert(normalizedPackageCollisionKey(packagePath.value)).inserted,
                  entry.byteCount <= limits.maxFileBytes
            else {
                throw RoomBackupError.invalidBackupManifest("Backup manifest entry is unsafe or collides.")
            }
            archiveMapping.append((archivePath, packagePath))
            manifestTotal = try checkedAdding(manifestTotal, entry.byteCount, cap: limits.maxArchiveBytes)
        }
        try validateCanonicalArchiveMapping(archiveMapping)
        guard manifestTotal == descriptor.uncompressedByteCount else {
            throw RoomBackupError.descriptorMismatch("Backup uncompressed byte count differs from the manifest.")
        }
        var extractedByPath: [String: RoomZIPEntryDigest] = [:]
        for digest in extracted {
            guard extractedByPath[digest.entryPath.value] == nil else {
                throw RoomBackupError.zipStructureInvalid("Backup ZIP has duplicate archive entries.")
            }
            extractedByPath[digest.entryPath.value] = digest
        }
        let expectedArchiveNames = Set(manifest.entries.map(\.archivePath)).union([Self.manifestEntryPath])
        guard Set(extractedByPath.keys) == expectedArchiveNames else {
            throw RoomBackupError.invalidBackupManifest("Backup archive and manifest closure differ.")
        }
        for entry in manifest.entries {
            guard let digest = extractedByPath[entry.archivePath],
                  digest.byteCount == entry.byteCount,
                  digest.sha256Hex == entry.sha256Hex
            else {
                throw RoomBackupError.invalidBackupManifest("Backup entry digest differs from its manifest.")
            }
        }
        guard let manifestZIPEntry = extractedByPath[Self.manifestEntryPath],
              manifestZIPEntry.mediaType == "application/json"
        else {
            throw RoomBackupError.invalidBackupManifest("backup-manifest.json is absent from the ZIP closure.")
        }
    }

    private static func validateWorkspace(_ workspace: URL) throws {
        var isDirectory = ObjCBool(false)
        guard
            workspace.isFileURL,
            FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            !isSymbolicLink(workspace)
        else {
            throw RoomBackupError.unsafeDestination(workspace.path)
        }
    }

    private static func validateContainedRegularFile(_ url: URL, workspace: URL) throws {
        let root = workspace.standardizedFileURL.pathComponents
        let candidate = url.standardizedFileURL.pathComponents
        guard candidate.count >= root.count,
              zip(root, candidate).allSatisfy({ $0 == $1 })
        else {
            throw RoomBackupError.unsafeDestination(url.path)
        }
        var current = workspace
        for component in candidate.dropFirst(root.count) {
            current.appendPathComponent(component)
            guard !isSymbolicLink(current) else {
                throw RoomBackupError.unsafeDestination(url.path)
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RoomBackupError.unsafeDestination(url.path)
        }
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let value = attributes[.size] as? NSNumber, value.int64Value >= 0 else {
            throw RoomBackupError.storageFailure("Backup file size is unavailable.")
        }
        return UInt64(value.int64Value)
    }

    /// Canonicalize the timestamp through the same JSON date codec used for
    /// the manifest. `JSONEncoder.iso8601` has second precision on the iOS 17
    /// baseline, so the descriptor and decoded manifest must bind that exact
    /// representation rather than an in-memory sub-second Date.
    private static func canonicalDate(_ value: Date) throws -> Date {
        struct DateEnvelope: Codable {
            let value: Date
        }
        do {
            let data = try RoomJSONCoding.makeEncoder().encode(DateEnvelope(value: value))
            return try RoomJSONCoding.makeDecoder().decode(DateEnvelope.self, from: data).value
        } catch {
            throw RoomBackupError.invalidBackupManifest("Backup timestamp cannot be canonicalized.")
        }
    }

    private static func checkedSum(_ values: [UInt64], cap: UInt64) throws -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            total = try checkedAdding(total, value, cap: cap)
        }
        return total
    }

    private static func checkedAdding(_ lhs: UInt64, _ rhs: UInt64, cap: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= cap else {
            throw RoomBackupError.archiveLimitExceeded
        }
        return sum
    }

    private static func normalizedPackageCollisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The package path remains in the signed manifest; ZIP paths are instead
    /// a fixed, app-owned indexed namespace. Both build and recovery require
    /// the same ordering so a safe-looking arbitrary `package/...` name can
    /// never become part of the backup format.
    private static func validateCanonicalArchiveMapping(
        _ mappings: [(RoomBackupArchivePath, RoomBackupPackagePath)]
    ) throws {
        for (offset, mapping) in mappings.sorted(by: { $0.1 < $1.1 }).enumerated() {
            let expected = canonicalArchivePath(
                index: offset + 1,
                packageRelativePath: mapping.1.value
            )
            guard mapping.0.value == expected else {
                throw RoomBackupError.invalidArchivePath(mapping.0.value)
            }
        }
    }

    private static func canonicalArchivePath(
        index: Int,
        packageRelativePath: String
    ) -> String {
        let extensionName = canonicalArchiveExtension(for: packageRelativePath)
        return String(format: "package/files/file-%04d.%@", index, extensionName)
    }

    private static func canonicalArchiveExtension(for packageRelativePath: String) -> String {
        let value = URL(fileURLWithPath: packageRelativePath).pathExtension.lowercased()
        guard !value.isEmpty,
              value.count <= 10,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...122).contains($0.value)
              })
        else {
            return "bin"
        }
        return value
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func backupError(_ error: Error) -> RoomBackupError {
        if let backupError = error as? RoomBackupError {
            return backupError
        }
        if let exportError = error as? RoomExportError {
            switch exportError {
            case .entryLimitExceeded:
                return .entryLimitExceeded
            case .sizeLimitExceeded(let path):
                return .sizeLimitExceeded(path)
            case .archiveLimitExceeded:
                return .archiveLimitExceeded
            case .sourceChangedAfterPreflight(let path):
                return .sourceChangedAfterPreflight(path)
            case .cancelled:
                return .cancelled
            default:
                return .zipStructureInvalid("Deterministic ZIP rejected the backup archive.")
            }
        }
        return .zipStructureInvalid("Deterministic ZIP failed while processing the backup archive.")
    }
}
