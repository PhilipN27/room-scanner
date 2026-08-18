import Foundation

public struct RoomAIRoomPackageArchiveResult: Sendable, Equatable {
    public var archiveURL: URL
    public var package: RoomAIRoomPackage
    public var manifestData: Data
    public var receipt: RoomZIPArchiveReceipt

    public init(
        archiveURL: URL,
        package: RoomAIRoomPackage,
        manifestData: Data,
        receipt: RoomZIPArchiveReceipt
    ) {
        self.archiveURL = archiveURL
        self.package = package
        self.manifestData = manifestData
        self.receipt = receipt
    }
}

public struct RoomAIRoomPackageArchiveValidation: Sendable, Equatable {
    public var package: RoomAIRoomPackage
    public var manifestData: Data
    public var entries: [RoomZIPEntryDigest]

    public init(
        package: RoomAIRoomPackage,
        manifestData: Data,
        entries: [RoomZIPEntryDigest]
    ) {
        self.package = package
        self.manifestData = manifestData
        self.entries = entries
    }
}

/// Deterministic AI Room Package ZIP32 STORE construction and independent
/// extraction-time validation. It never writes into or changes source files.
public enum RoomAIRoomPackageArchive {
    public static let manifestEntryPath = "manifest.json"
    public static let maximumManifestBytes: UInt64 = 8 * 1_024 * 1_024

    public static func build(
        preparation: RoomAIRoomPackagePreparation,
        disclosureReview: RoomDisclosureReview,
        archiveURL: URL,
        workspaceURL: URL,
        limits: RoomZIPLimits = RoomZIPLimits()
    ) async throws -> RoomAIRoomPackageArchiveResult {
        let workspace = workspaceURL.standardizedFileURL
        try validateEmptyWorkspace(workspace)
        let package = try preparation.finalize(disclosureReview: disclosureReview)
        let manifestData = try RoomAIRoomPackageBuilder.canonicalManifestData(package)
        guard UInt64(manifestData.count) <= maximumManifestBytes else {
            throw RoomAIRoomPackageError.invalidManifest("manifest-size-limit")
        }
        try validateFrozenSources(preparation, package: package)

        let artifactInputs = preparation.includedSources.map {
            RoomZIPInput(
                sourceURL: $0.sourceURL,
                entryPath: $0.entryPath,
                mediaType: $0.mediaType
            )
        }
        let actualDigests = try await RoomDeterministicZIP.preflight(
            inputs: artifactInputs,
            limits: limits
        )
        let frozenDigests = preparation.includedSources.map(\.frozenDigest).sorted {
            $0.entryPath < $1.entryPath
        }
        guard actualDigests == frozenDigests else {
            throw RoomExportError.sourceChangedAfterPreflight("AI Room Package artifact")
        }

        let manifestURL = workspace.appendingPathComponent(manifestEntryPath)
        guard !pathExists(manifestURL), !isSymbolicLink(manifestURL) else {
            throw RoomExportError.destinationAlreadyExists(manifestURL.path)
        }
        do {
            try manifestData.write(to: manifestURL, options: [.withoutOverwriting])
        } catch {
            throw RoomAIRoomPackageError.invalidManifest("manifest-write")
        }
        let manifestInput = RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(manifestEntryPath),
            mediaType: "application/json"
        )
        let manifestDigests = try await RoomDeterministicZIP.preflight(
            inputs: [manifestInput],
            limits: limits
        )
        let expectedDigests = (frozenDigests + manifestDigests).sorted {
            $0.entryPath < $1.entryPath
        }
        let receipt = try await RoomDeterministicZIP.write(
            inputs: artifactInputs + [manifestInput],
            to: archiveURL,
            limits: limits,
            expectedDigests: expectedDigests
        )

        // A freshly written archive is not shareable until the independent
        // extractor has re-read its canonical manifest and closed the ledger.
        let verificationURL = workspace.appendingPathComponent(".roomscan-ai-package-validation")
        var verificationCreated = false
        do {
            try FileManager.default.createDirectory(
                at: verificationURL,
                withIntermediateDirectories: false
            )
            verificationCreated = true
            let validation = try await extractAndValidate(
                archiveURL: archiveURL,
                into: verificationURL,
                expectedSourceRevision: preparation.sourceRevision,
                expectedProfile: preparation.profile,
                limits: limits
            )
            guard validation.package == package,
                  validation.manifestData == manifestData
            else {
                throw RoomAIRoomPackageError.archiveClosureMismatch("post-build-package")
            }
            try FileManager.default.removeItem(at: verificationURL)
            verificationCreated = false
        } catch {
            if verificationCreated { try? FileManager.default.removeItem(at: verificationURL) }
            if pathExists(archiveURL), !isSymbolicLink(archiveURL) {
                try? FileManager.default.removeItem(at: archiveURL)
            }
            throw error
        }
        return RoomAIRoomPackageArchiveResult(
            archiveURL: archiveURL,
            package: package,
            manifestData: manifestData,
            receipt: receipt
        )
    }

    public static func extractAndValidate(
        archiveURL: URL,
        into destinationURL: URL,
        expectedSourceRevision: RoomRedesignSourceRevision? = nil,
        expectedProfile: RoomAIRoomPackageProfile? = nil,
        limits: RoomZIPLimits = RoomZIPLimits()
    ) async throws -> RoomAIRoomPackageArchiveValidation {
        let entries = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
            from: archiveURL,
            into: destinationURL,
            limits: limits,
            maximumByteCountByEntryPath: [manifestEntryPath: maximumManifestBytes]
        )
        guard let manifestEntry = entries.first(where: {
            $0.entryPath.value == manifestEntryPath
        }) else {
            throw RoomAIRoomPackageError.invalidManifest("missing-manifest")
        }
        let manifestURL = destinationURL.appendingPathComponent(manifestEntryPath)
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw RoomAIRoomPackageError.invalidManifest("unreadable-manifest")
        }
        guard UInt64(manifestData.count) == manifestEntry.byteCount,
              UInt64(manifestData.count) <= maximumManifestBytes,
              RoomSHA256.hexDigest(of: manifestData) == manifestEntry.sha256Hex
        else {
            throw RoomAIRoomPackageError.invalidManifest("manifest-identity")
        }
        let package: RoomAIRoomPackage
        do {
            guard case let .aiRoomPackage(decoded) = try RoomRedesignContractValidator.validate(
                data: manifestData
            ) else {
                throw RoomAIRoomPackageError.invalidManifest("wrong-contract-kind")
            }
            guard try RoomRedesignCanonicalJSON.encode(decoded) == manifestData else {
                throw RoomAIRoomPackageError.invalidManifest("noncanonical-manifest")
            }
            try decoded.validate()
            package = decoded
        } catch let error as RoomAIRoomPackageError {
            throw error
        } catch {
            throw RoomAIRoomPackageError.invalidManifest("strict-manifest-validation")
        }
        if let expectedSourceRevision, package.sourceRevision != expectedSourceRevision {
            throw RoomAIRoomPackageError.sourceRevisionMismatch
        }
        if let expectedProfile, package.profile != expectedProfile {
            throw RoomAIRoomPackageError.invalidManifest("profile-mismatch")
        }

        let included = package.artifacts.filter { $0.disposition == .included }
        let expectedPaths = Set(
            [manifestEntryPath] + included.compactMap(\.relativePath)
        )
        let actualPaths = Set(entries.map { $0.entryPath.value })
        guard expectedPaths == actualPaths,
              expectedPaths.count == included.count + 1
        else {
            throw RoomAIRoomPackageError.archiveClosureMismatch("entry-paths")
        }
        let entryByPath = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.entryPath.value, $0)
        })
        for artifact in included {
            guard let relativePath = artifact.relativePath,
                  let sha256 = artifact.sha256,
                  let byteCount = artifact.byteCount,
                  let entry = entryByPath[relativePath],
                  entry.sha256Hex == sha256,
                  entry.byteCount == byteCount
            else {
                throw RoomAIRoomPackageError.archiveClosureMismatch(artifact.artifactID)
            }
        }
        guard package.artifactPlan == package.artifacts.map(\.slot) else {
            throw RoomAIRoomPackageError.archiveClosureMismatch("plan-ledger")
        }
        return RoomAIRoomPackageArchiveValidation(
            package: package,
            manifestData: manifestData,
            entries: entries
        )
    }

    private static func validateFrozenSources(
        _ preparation: RoomAIRoomPackagePreparation,
        package: RoomAIRoomPackage
    ) throws {
        let includedArtifacts = package.artifacts.filter { $0.disposition == .included }
        guard includedArtifacts.count == preparation.includedSources.count,
              Set(includedArtifacts.map(\.artifactID)) == Set(preparation.includedSources.map(\.slot.artifactID))
        else {
            throw RoomAIRoomPackageError.ledgerMismatch
        }
        let artifactByID = Dictionary(uniqueKeysWithValues: includedArtifacts.map {
            ($0.artifactID, $0)
        })
        for source in preparation.includedSources {
            guard let artifact = artifactByID[source.slot.artifactID],
                  artifact.slot == source.slot,
                  artifact.relativePath == source.entryPath.value,
                  artifact.mediaType == source.mediaType,
                  artifact.sha256 == source.frozenDigest.sha256Hex,
                  artifact.byteCount == source.frozenDigest.byteCount,
                  source.frozenDigest.mediaType == source.mediaType
            else {
                throw RoomAIRoomPackageError.ledgerMismatch
            }
        }
    }

    private static func validateEmptyWorkspace(_ workspace: URL) throws {
        guard workspace.isFileURL,
              !isSymbolicLink(workspace),
              directoryExists(workspace)
        else {
            throw RoomExportError.unsafeDestination(workspace.path)
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: nil
        )
        guard children.isEmpty else {
            throw RoomExportError.unsafeDestination("AI package workspace must be empty.")
        }
    }

    private static func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
