import Foundation

public struct RoomPublicationArchiveResult: Sendable, Equatable {
    public var archiveURL: URL
    public var manifest: RoomPublishedPublicationManifest
    public var manifestData: Data
    public var presentationData: Data
    public var receipt: RoomZIPArchiveReceipt

    public init(
        archiveURL: URL,
        manifest: RoomPublishedPublicationManifest,
        manifestData: Data,
        presentationData: Data,
        receipt: RoomZIPArchiveReceipt
    ) {
        self.archiveURL = archiveURL
        self.manifest = manifest
        self.manifestData = manifestData
        self.presentationData = presentationData
        self.receipt = receipt
    }
}

public struct RoomPublicationArchiveValidation: Sendable, Equatable {
    public var manifest: RoomPublishedPublicationManifest
    public var draft: RoomPublishedSnapshotDraft
    public var presentationData: Data
    public var entries: [RoomZIPEntryDigest]

    public init(
        manifest: RoomPublishedPublicationManifest,
        draft: RoomPublishedSnapshotDraft,
        presentationData: Data,
        entries: [RoomZIPEntryDigest]
    ) {
        self.manifest = manifest
        self.draft = draft
        self.presentationData = presentationData
        self.entries = entries
    }
}

/// The archive-specific half of the Slice 6 allowlist boundary. Full outer
/// archive construction and inspection are added below; this helper already
/// makes an AI-ready ZIP prove its actual profile, manifest, source binding,
/// and closure before it can enter a publication selection ledger.
public enum RoomPublicationArchive {
    public static let manifestEntryPath = "publication-manifest.json"
    public static let presentationEntryPath = "presentation.json"

    public static func build(
        ready: RoomPublishedSnapshotReady,
        archiveURL: URL,
        workspaceURL: URL,
        limits: RoomZIPLimits = RoomZIPLimits(
            maxEntries: 514,
            maxEntryBytes: 512 * 1_024 * 1_024,
            maxArchiveBytes: 768 * 1_024 * 1_024
        )
    ) async throws -> RoomPublicationArchiveResult {
        let preparation = ready.preparation
        try ready.approval.validate(
            expectedSourceBindingsSHA256: preparation.sourceBindingsSHA256,
            expectedSelectionManifestSHA256: preparation.selectionManifestSHA256
        )
        try requireOwnedEmptyWorkspace(workspaceURL)
        let presentationData = try preparation.draft.canonicalPresentationData()
        guard presentationData == preparation.presentationData else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "presentation",
                reason: "The prepared public presentation bytes changed before archive construction."
            )
        }
        let presentationSHA256 = RoomSHA256.hexDigest(of: presentationData)
        let assets = preparation.preparedAssets.map(\.ledger)
        let manifest = RoomPublishedPublicationManifest(
            snapshotKind: preparation.draft.kind,
            sourceBindings: preparation.sourceBindings,
            sourceBindingsSHA256: preparation.sourceBindingsSHA256,
            selectionManifestSHA256: preparation.selectionManifestSHA256,
            approval: ready.approval,
            presentationSHA256: presentationSHA256,
            assets: assets
        )
        try manifest.validate()
        try RoomPublishedSnapshotRules.validateSourceBindings(
            manifest.sourceBindings,
            expectedRoomKeys: preparation.draft.orderedRoomKeys
        )
        try RoomPublishedSnapshotRules.validatePresentationReferences(
            draft: preparation.draft,
            ledger: assets
        )
        let manifestData = try RoomRedesignCanonicalJSON.encode(manifest)

        let workspace = workspaceURL.standardizedFileURL
        let manifestURL = workspace.appendingPathComponent(manifestEntryPath)
        let presentationURL = workspace.appendingPathComponent(presentationEntryPath)
        try writeNew(manifestData, to: manifestURL)
        try writeNew(presentationData, to: presentationURL)
        var inputs: [RoomZIPInput] = [
            .init(
                sourceURL: manifestURL,
                entryPath: try RoomExportEntryPath(manifestEntryPath),
                mediaType: "application/json"
            ),
            .init(
                sourceURL: presentationURL,
                entryPath: try RoomExportEntryPath(presentationEntryPath),
                mediaType: "application/json"
            ),
        ]
        for preparedAsset in preparation.preparedAssets {
            let sourceURL: URL
            switch preparedAsset.source {
            case let .data(data):
                let destination = workspace.appendingPathComponent(preparedAsset.ledger.relativePath)
                try writeNew(data, to: destination)
                sourceURL = destination
            case let .file(url):
                sourceURL = url
            }
            inputs.append(.init(
                sourceURL: sourceURL,
                entryPath: try RoomExportEntryPath(preparedAsset.ledger.relativePath),
                mediaType: preparedAsset.ledger.mediaType
            ))
        }
        let expectedDigests = try await RoomDeterministicZIP.preflight(inputs: inputs, limits: limits)
        try verifyPreparedIdentity(
            expectedDigests: expectedDigests,
            manifestData: manifestData,
            presentationData: presentationData,
            assets: assets
        )
        let receipt = try await RoomDeterministicZIP.write(
            inputs: inputs,
            to: archiveURL,
            limits: limits,
            expectedDigests: expectedDigests
        )

        let verificationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "roomscan-publication-postbuild-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: verificationRoot, withIntermediateDirectories: false)
        do {
            let validation = try await extractAndValidate(
                archiveURL: archiveURL,
                into: verificationRoot,
                limits: limits
            )
            guard validation.manifest == manifest, validation.presentationData == presentationData else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "archive",
                    reason: "The post-build publication archive does not reproduce its exact approved control and public presentation bytes."
                )
            }
            try FileManager.default.removeItem(at: verificationRoot)
        } catch {
            try? FileManager.default.removeItem(at: verificationRoot)
            if isSafeRegularFile(archiveURL) { try? FileManager.default.removeItem(at: archiveURL) }
            throw error
        }
        return RoomPublicationArchiveResult(
            archiveURL: archiveURL,
            manifest: manifest,
            manifestData: manifestData,
            presentationData: presentationData,
            receipt: receipt
        )
    }

    public static func extractAndValidate(
        archiveURL: URL,
        into destinationURL: URL,
        limits: RoomZIPLimits = RoomZIPLimits(
            maxEntries: 514,
            maxEntryBytes: 512 * 1_024 * 1_024,
            maxArchiveBytes: 768 * 1_024 * 1_024
        )
    ) async throws -> RoomPublicationArchiveValidation {
        let entries = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
            from: archiveURL,
            into: destinationURL,
            limits: limits,
            maximumByteCountByEntryPath: [
                manifestEntryPath: RoomPublishedSnapshotRules.maximumGeometryBytes,
                presentationEntryPath: RoomPublishedSnapshotRules.maximumGeometryBytes,
            ]
        )
        let entryByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.entryPath.value, $0) })
        guard let manifestEntry = entryByPath[manifestEntryPath],
              let presentationEntry = entryByPath[presentationEntryPath]
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "archive",
                reason: "A publication archive needs one control manifest and one portal-safe presentation."
            )
        }
        let manifestData = try readExactEntry(
            destinationURL.appendingPathComponent(manifestEntryPath),
            entry: manifestEntry
        )
        let presentationData = try readExactEntry(
            destinationURL.appendingPathComponent(presentationEntryPath),
            entry: presentationEntry
        )
        let manifest = try decodeCanonicalManifest(manifestData)
        let draft = try decodeCanonicalPresentation(presentationData, expectedKind: manifest.snapshotKind)
        let canonicalPresentation = try draft.canonicalPresentationData()
        guard canonicalPresentation == presentationData,
              RoomSHA256.hexDigest(of: presentationData) == manifest.presentationSHA256
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "presentation",
                reason: "Publication presentation bytes must be canonical and match the immutable control digest."
            )
        }
        try RoomPublishedSnapshotRules.validateSourceBindings(
            manifest.sourceBindings,
            expectedRoomKeys: draft.orderedRoomKeys
        )
        try RoomPublishedSnapshotRules.validatePresentationReferences(
            draft: draft,
            ledger: manifest.assets
        )
        let expectedPaths = Set([manifestEntryPath, presentationEntryPath] + manifest.assets.map(\.relativePath))
        let actualPaths = Set(entries.map(\.entryPath.value))
        guard expectedPaths == actualPaths,
              expectedPaths.count == manifest.assets.count + 2
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "archive.entries",
                reason: "Publication archive closure must contain exactly its control manifest, public presentation, and allowlisted asset ledger."
            )
        }
        for asset in manifest.assets {
            guard let entry = entryByPath[asset.relativePath],
                  entry.sha256Hex == asset.sha256,
                  entry.byteCount == asset.byteCount
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "assets.\(asset.assetID)",
                    reason: "Published asset bytes must match their immutable ledger identity."
                )
            }
            let assetURL = destinationURL.appendingPathComponent(asset.relativePath)
            try await validateExtractedAsset(
                assetURL: assetURL,
                asset: asset,
                sourceBindings: manifest.sourceBindings
            )
        }
        return RoomPublicationArchiveValidation(
            manifest: manifest,
            draft: draft,
            presentationData: presentationData,
            entries: entries
        )
    }

    static func prepareAIReadyAsset(
        asset: RoomPublishedAssetInput,
        sourceBindings: [RoomPublishedSourceBinding]
    ) async throws -> RoomPublishedPreparedAsset {
        guard asset.assetClass == .aiReadyPackage,
              case let .aiReadyPackage(input) = asset.payload,
              asset.publicRoomKey == input.publicRoomKey
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets",
                reason: "Only the explicit AI-ready input may carry a ZIP archive."
            )
        }
        try RoomPublishedSnapshotRules.requireIdentifier(input.publicRoomKey, at: "assets.publicRoomKey")
        try RoomPublishedSnapshotRules.requireIdentifier(input.expectedPackageID, at: "assets.expectedPackageID")
        guard let sourceBinding = sourceBindings.first(where: {
            $0.publicRoomKey == input.publicRoomKey
        }) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.publicRoomKey",
                reason: "AI-ready downloads must bind to one selected public room."
            )
        }
        let values = try input.archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              UInt64(size) <= RoomPublishedSnapshotRules.maximumAIReadyArchiveBytes
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.archiveURL",
                reason: "AI-ready archive input must be one bounded regular file."
            )
        }

        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "roomscan-publication-ai-ready-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let validated = try await RoomAIRoomPackageArchive.extractAndValidate(
            archiveURL: input.archiveURL,
            into: stage,
            expectedSourceRevision: sourceBinding.sourceRevision,
            expectedProfile: .aiReady,
            limits: RoomZIPLimits(
                maxEntries: 4_096,
                maxEntryBytes: RoomPublishedSnapshotRules.maximumAIReadyArchiveBytes,
                maxArchiveBytes: RoomPublishedSnapshotRules.maximumAIReadyArchiveBytes
            )
        )
        guard validated.package.packageID == input.expectedPackageID,
              validated.package.profile == .aiReady,
              validated.package.sourceRevision == sourceBinding.sourceRevision
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.aiReadyPackage",
                reason: "AI-ready archive facts must match its selected package and exact room source binding."
            )
        }
        let binding = RoomPublishedAIReadyPackageBinding(
            packageID: validated.package.packageID,
            manifestSHA256: RoomSHA256.hexDigest(of: validated.manifestData),
            publicRoomKey: input.publicRoomKey,
            artifactPlanSHA256: validated.package.artifactPlanSHA256,
            selectionSHA256: validated.package.selectionSHA256
        )
        let ledger = RoomPublishedAssetLedgerEntry(
            assetID: asset.assetID,
            publicRoomKey: input.publicRoomKey,
            assetClass: .aiReadyPackage,
            relativePath: "assets/\(asset.assetID).zip",
            sha256: try RoomSHA256.hexDigest(ofFile: input.archiveURL),
            byteCount: UInt64(size),
            mediaType: "application/zip",
            aiReadyPackageBinding: binding
        )
        try ledger.validate(at: "assets.\(asset.assetID)")
        return RoomPublishedPreparedAsset(ledger: ledger, source: .file(input.archiveURL))
    }

    private static func verifyPreparedIdentity(
        expectedDigests: [RoomZIPEntryDigest],
        manifestData: Data,
        presentationData: Data,
        assets: [RoomPublishedAssetLedgerEntry]
    ) throws {
        let byPath = Dictionary(uniqueKeysWithValues: expectedDigests.map { ($0.entryPath.value, $0) })
        guard let manifest = byPath[manifestEntryPath],
              manifest.byteCount == UInt64(manifestData.count),
              manifest.sha256Hex == RoomSHA256.hexDigest(of: manifestData),
              let presentation = byPath[presentationEntryPath],
              presentation.byteCount == UInt64(presentationData.count),
              presentation.sha256Hex == RoomSHA256.hexDigest(of: presentationData)
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "archive",
                reason: "Generated publication records changed before ZIP preflight."
            )
        }
        for asset in assets {
            guard let entry = byPath[asset.relativePath],
                  entry.byteCount == asset.byteCount,
                  entry.sha256Hex == asset.sha256,
                  entry.mediaType == asset.mediaType
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "assets.\(asset.assetID)",
                    reason: "Prepared source bytes changed before publication archive construction."
                )
            }
        }
    }

    private static func decodeCanonicalManifest(_ data: Data) throws -> RoomPublishedPublicationManifest {
        guard case let .publicationArchive(manifest) = try RoomRedesignContractValidator.validate(data: data) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "publication-manifest.json",
                reason: "Publication control data must use the closed Slice 6 archive contract."
            )
        }
        guard try RoomRedesignCanonicalJSON.encode(manifest) == data else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "publication-manifest.json",
                reason: "Publication control manifest must use canonical JSON bytes."
            )
        }
        return manifest
    }

    private static func decodeCanonicalPresentation(
        _ data: Data,
        expectedKind: RoomPublishedSnapshotKind
    ) throws -> RoomPublishedSnapshotDraft {
        let document = try RoomRedesignContractValidator.validate(data: data)
        let draft: RoomPublishedSnapshotDraft
        switch document {
        case let .publishedRoomSnapshot(value):
            draft = .room(value)
        case let .publishedPropertySnapshot(value):
            draft = .property(value)
        default:
            throw RoomRedesignContractValidationError.invalidValue(
                path: "presentation.json",
                reason: "Publication presentation must use one Slice 6 public snapshot contract."
            )
        }
        guard draft.kind == expectedKind else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "presentation.json",
                reason: "Publication presentation kind must match the immutable control manifest."
            )
        }
        return draft
    }

    private static func validateExtractedAsset(
        assetURL: URL,
        asset: RoomPublishedAssetLedgerEntry,
        sourceBindings: [RoomPublishedSourceBinding]
    ) async throws {
        let data: Data
        switch asset.assetClass {
        case .webGeometry:
            data = try Data(contentsOf: assetURL)
            let geometry: RoomPublishedWebGeometry
            do {
                geometry = try RoomJSONCoding.makeDecoder().decode(RoomPublishedWebGeometry.self, from: data)
            } catch {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets.\(asset.assetID)", reason: "Web geometry must decode as the typed bounded public model.")
            }
            try geometry.validate()
            guard try RoomRedesignCanonicalJSON.encode(geometry) == data else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets.\(asset.assetID)", reason: "Web geometry bytes must be canonical JSON.")
            }
        case .webTexture, .selectedImage, .floorPlan, .approvedConcept, .brandingLogo:
            data = try Data(contentsOf: assetURL)
            _ = try RoomPublishedRasterValidator.validate(
                data,
                mediaType: asset.mediaType
            )
        case .aiReadyPackage:
            guard let binding = asset.aiReadyPackageBinding,
                  let sourceBinding = sourceBindings.first(where: { $0.publicRoomKey == binding.publicRoomKey })
            else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets.\(asset.assetID)", reason: "AI-ready asset binding must resolve one source room.")
            }
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent(
                "roomscan-publication-ai-recheck-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: stage) }
            let package = try await RoomAIRoomPackageArchive.extractAndValidate(
                archiveURL: assetURL,
                into: stage,
                expectedSourceRevision: sourceBinding.sourceRevision,
                expectedProfile: .aiReady,
                limits: RoomZIPLimits(
                    maxEntries: 4_096,
                    maxEntryBytes: RoomPublishedSnapshotRules.maximumAIReadyArchiveBytes,
                    maxArchiveBytes: RoomPublishedSnapshotRules.maximumAIReadyArchiveBytes
                )
            )
            guard package.package.packageID == binding.packageID,
                  RoomSHA256.hexDigest(of: package.manifestData) == binding.manifestSHA256,
                  package.package.artifactPlanSHA256 == binding.artifactPlanSHA256,
                  package.package.selectionSHA256 == binding.selectionSHA256
            else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets.\(asset.assetID)", reason: "AI-ready archive facts must match their immutable control binding.")
            }
        }
    }

    private static func readExactEntry(_ url: URL, entry: RoomZIPEntryDigest) throws -> Data {
        let data = try Data(contentsOf: url)
        guard UInt64(data.count) == entry.byteCount,
              RoomSHA256.hexDigest(of: data) == entry.sha256Hex
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: "archive", reason: "Extracted entry bytes do not match streaming ZIP verification.")
        }
        return data
    }

    private static func requireOwnedEmptyWorkspace(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RoomExportError.unsafeDestination(url.path)
        }
        guard try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).isEmpty else {
            throw RoomExportError.unsafeDestination("Publication workspace must be empty.")
        }
    }

    private static func writeNew(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RoomExportError.destinationAlreadyExists(url.path)
        }
        try data.write(to: url, options: [.withoutOverwriting])
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
