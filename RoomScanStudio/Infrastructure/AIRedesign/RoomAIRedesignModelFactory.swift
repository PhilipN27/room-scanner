import CoreGraphics
import Foundation
import ImageIO
import RoomScanCore

enum RoomAIRedesignModelFactoryError: Error, LocalizedError {
    case missingHeadRevision
    case missingConfirmedOrientation
    case staleSourceRevision
    case unsafeReplacement

    var errorDescription: String? {
        switch self {
        case .missingHeadRevision:
            "The sealed head revision could not be loaded."
        case .missingConfirmedOrientation:
            "Review and save the room orientation before opening AI Room Package."
        case .staleSourceRevision:
            "The room revision changed. Close this workspace and open the current room again."
        case .unsafeReplacement:
            "The replacement image could not be safely decoded and bound to this room revision."
        }
    }
}

/// Creates a revision-bound production model without giving the SwiftUI layer
/// package URLs, source-package write access, or any account/network service.
/// Every preparation reloads and rechecks the immutable revision before it
/// freezes outbound bytes into an app-owned export lease.
@MainActor
final class RoomAIRedesignModelFactory: RoomPublicationAIReadyPackageProviding {
    private let controller: RoomLibraryController
    private let workspaceFactory: RoomExportWorkspaceFactory
    private let conceptStore: LocalRoomConceptStore
    private let conceptCoordinator: RoomConceptImportCoordinator
    private let conceptPackageProvenance: RoomAIConceptPackageProvenanceRegistry
    private let mintPackageIdentifier: () -> String

    init(
        controller: RoomLibraryController,
        workspaceFactory: RoomExportWorkspaceFactory,
        projectRootURL: URL,
        conceptRootURL: URL,
        conceptImportScratchRootURL: URL,
        provenanceRootURL: URL? = nil,
        mintPackageIdentifier: @escaping () -> String = {
            "ai-room-\(UUID().uuidString.lowercased())"
        }
    ) {
        self.controller = controller
        self.workspaceFactory = workspaceFactory
        self.mintPackageIdentifier = mintPackageIdentifier
        let store = LocalRoomConceptStore(
            rootURL: conceptRootURL,
            sourcePackageRootURL: projectRootURL
        )
        conceptStore = store
        conceptCoordinator = RoomConceptImportCoordinator(
            store: store,
            scratchRootURL: conceptImportScratchRootURL
        )
        conceptPackageProvenance = RoomAIConceptPackageProvenanceRegistry(
            rootURL: provenanceRootURL ?? conceptRootURL
                .deletingLastPathComponent()
                .appendingPathComponent("AIRedesignProvenance", isDirectory: true),
            sourcePackageRootURL: projectRootURL
        )
    }

    /// Captures the exact additive companion closure for an immutable local
    /// revision. This is intentionally separate from `makeModel`: migration
    /// must work for a valid local room even when the AI editor has never been
    /// opened or an orientation has not been confirmed.
    func professionalWorkingSetCompanionPreparation(
        sourceRevision: RoomRedesignSourceRevision
    ) async throws -> RoomProfessionalWorkingSetCompanionPreparation {
        let package = try await controller.loadPackage(projectID: sourceRevision.projectID)
        guard package.manifest.headRevisionID == sourceRevision.revisionID else {
            throw RoomAIRedesignModelFactoryError.staleSourceRevision
        }
        let currentBinding = try await controller.redesignSourceBinding(
            projectID: sourceRevision.projectID,
            revisionID: sourceRevision.revisionID
        )
        guard currentBinding == sourceRevision else {
            throw RoomAIRedesignModelFactoryError.staleSourceRevision
        }

        let redesign = try await controller.professionalRedesignSnapshot(
            sourceRevision: sourceRevision
        )
        let localRedesign = try await controller.redesignState(sourceRevision: sourceRevision)
        let cameraIDs = localRedesign?.orientation.canonicalCameras
            .map(\.cameraID)
            .sorted() ?? []
        let sourcePackages = try conceptPackageProvenance.bindings(for: sourceRevision)
        let conceptContext = RoomConceptSetValidationContext(
            expectedSourceRevision: sourceRevision,
            currentCanonicalCameraIDs: cameraIDs,
            validatedSourceAIRoomPackages: sourcePackages
        )
        let conceptSnapshot = try await conceptStore.snapshot(context: conceptContext)
        let transport = try RoomProfessionalConceptTransportSnapshot(
            sourceSnapshot: conceptSnapshot,
            sourcePackageManifestData: try conceptPackageProvenance.canonicalManifestData(
                for: sourceRevision
            ),
            currentCanonicalCameraIDs: cameraIDs
        )
        return try transport.workingSetCompanionPreparation(
            additionalCompanions: try redesign?.workingSetCompanions() ?? []
        )
    }

    /// Publication reads only already-approved, source-bound Concept Set
    /// attachment bytes through the existing concept-store validation seam.
    /// It never returns a Concept Set path, package URL, private comments, or
    /// provider request text. The publication-specific fresh raster sanitizer
    /// runs later when the owner explicitly selects one of these candidates.
    func approvedPublicationConceptAssets(
        sourceRevision: RoomRedesignSourceRevision
    ) async throws -> [RoomPublicationApprovedConceptAsset] {
        let package = try await controller.loadPackage(projectID: sourceRevision.projectID)
        guard package.manifest.headRevisionID == sourceRevision.revisionID,
              try await controller.redesignSourceBinding(
                projectID: sourceRevision.projectID,
                revisionID: sourceRevision.revisionID
              ) == sourceRevision
        else {
            throw RoomAIRedesignModelFactoryError.staleSourceRevision
        }
        // A room without a confirmed orientation cannot have a provenance
        // valid approved Concept Set. That is an honest absence, not a reason
        // to synthesize a comparison. In contrast, a present but stale or
        // invalid set below throws and blocks publication rather than being
        // silently omitted.
        guard let companion = try await controller.redesignState(
            sourceRevision: sourceRevision
        ) else {
            return []
        }
        guard companion.sourceRevision == sourceRevision else {
            throw RoomAIRedesignModelFactoryError.staleSourceRevision
        }
        guard companion.orientation.source == .confirmed || companion.orientation.source == .manual else {
            return []
        }
        let cameraIDs = companion.orientation.canonicalCameras.map(\.cameraID).sorted()
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: sourceRevision,
            currentCanonicalCameraIDs: cameraIDs,
            validatedSourceAIRoomPackages: try conceptPackageProvenance.bindings(
                for: sourceRevision
            )
        )
        let concepts = try await conceptCoordinator.list(
            context: context,
            archiveState: .active
        )
        // `sortKey` never crosses this private provenance boundary. The
        // resulting selection identifiers and labels are fresh public ordinals
        // so Concept Set/attachment IDs never enter a presentation document.
        var candidates: [(sortKey: String, data: Data, declaredFilename: String)] = []
        for concept in concepts where concept.approvalState == .approved {
            for attachment in concept.attachments where attachment.mediaType == "image/jpeg" || attachment.mediaType == "image/png" {
                let data = try await conceptCoordinator.attachmentData(
                    conceptSetID: concept.conceptSetID,
                    attachmentID: attachment.attachmentID,
                    context: context
                )
                candidates.append((
                    sortKey: "\(concept.conceptSetID)\u{0}\(attachment.attachmentID)",
                    data: data,
                    declaredFilename: attachment.relativePath
                ))
            }
        }
        return candidates
            .sorted { $0.sortKey < $1.sortKey }
            .enumerated()
            .map { index, candidate in
                .init(
                    choice: .init(
                        id: "approved-concept-\(String(format: "%03d", index + 1))",
                        label: "Approved concept \(index + 1)"
                    ),
                    data: candidate.data,
                    declaredFilename: candidate.declaredFilename
                )
            }
    }

    /// Returns only a transient local capability for an already-finalized
    /// `aiReady` archive. It rechecks the exact current source head before
    /// asking the private provenance registry to independently validate the
    /// retained bytes. No archive URL, package ID, or provenance detail is
    /// exposed to a view, journal, hosted transport, or public document.
    func validatedAIReadyPackage(
        for sourceRevision: RoomRedesignSourceRevision
    ) async -> RoomPublicationAIReadyPackageCandidate? {
        do {
            let package = try await controller.loadPackage(projectID: sourceRevision.projectID)
            guard package.manifest.headRevisionID == sourceRevision.revisionID,
                  try await controller.redesignSourceBinding(
                      projectID: sourceRevision.projectID,
                      revisionID: sourceRevision.revisionID
                  ) == sourceRevision
            else { return nil }
            return await conceptPackageProvenance.publicationAIReadyPackageCandidate(
                for: sourceRevision
            )
        } catch {
            // Absence is fail-closed: publication remains available without
            // an AI package rather than treating a stale local archive as a
            // downloadable public derivative.
            return nil
        }
    }

    /// Builds the app wrapper around Core's package-first recovery primitive.
    /// The exact canonical provenance bytes are installed only when Core
    /// reports original-ID recovery; recovered copies never reach this
    /// closure.
    func makeProfessionalRecoveryCoordinator(
        scratchRootURL: URL,
        journal: ProfessionalProjectSyncJournal?,
        faultInjector: any RoomProfessionalRecoveryFaultInjecting = NoRoomProfessionalRecoveryFaultInjector()
    ) throws -> ProfessionalProjectRecoveryCoordinator {
        let coordinator = try controller.makeProfessionalRecoveryCoordinator(
            conceptStore: conceptStore,
            scratchRootURL: scratchRootURL,
            faultInjector: faultInjector
        )
        let registry = conceptPackageProvenance
        return ProfessionalProjectRecoveryCoordinator(dependencies: .init(
            coreRecoveryCoordinator: coordinator,
            scratchRootURL: scratchRootURL,
            journal: journal,
            installCanonicalProvenance: { snapshot in
                try registry.installCanonical(snapshot)
            }
        ))
    }

    func makeModel(projectID: String) async throws -> RoomAIRedesignProductionModel {
        let package = try await controller.loadPackage(projectID: projectID)
        let revisionID = package.manifest.headRevisionID
        let sourceRevision = try await controller.redesignSourceBinding(
            projectID: projectID,
            revisionID: revisionID
        )
        guard let revision = package.revisions.first(where: {
            $0.manifest.revisionID == revisionID
        }) else {
            throw RoomAIRedesignModelFactoryError.missingHeadRevision
        }
        guard let companion = try await controller.redesignState(
            sourceRevision: sourceRevision
        ) else {
            throw RoomAIRedesignModelFactoryError.missingConfirmedOrientation
        }
        try companion.validate()
        guard companion.sourceRevision == sourceRevision,
              companion.orientation.source == .confirmed
                || companion.orientation.source == .manual
        else {
            throw RoomAIRedesignModelFactoryError.missingConfirmedOrientation
        }

        let featureBindings = Self.featureBindings(
            snapshot: revision.payload.semanticSnapshot,
            intent: companion.redesignIntent
        )
        let cameraIDs = companion.orientation.canonicalCameras
            .map(\.cameraID)
            .sorted()
        let validatedSourcePackages = try conceptPackageProvenance.bindings(
            for: sourceRevision
        )
        let conceptContext = RoomConceptSetValidationContext(
            expectedSourceRevision: sourceRevision,
            currentCanonicalCameraIDs: cameraIDs,
            validatedSourceAIRoomPackages: validatedSourcePackages
        )
        let replacementRegistry = RoomAIReplacementRegistry(
            sourceRevision: sourceRevision
        )
        let controller = controller
        let workspaceFactory = workspaceFactory
        let displayToFeatureID = featureBindings.displayToFeatureID
        let conceptPackageProvenance = conceptPackageProvenance
        let mintPackageIdentifier = mintPackageIdentifier

        let dependencies = RoomAIRedesignProductionDependencies(
            materialize: { request in
                guard request.sourceRevision == sourceRevision else {
                    throw RoomAIRedesignModelFactoryError.staleSourceRevision
                }
                let currentBinding = try await controller.redesignSourceBinding(
                    projectID: sourceRevision.projectID,
                    revisionID: sourceRevision.revisionID
                )
                guard currentBinding == sourceRevision else {
                    throw RoomAIRedesignModelFactoryError.staleSourceRevision
                }
                let currentPackage = try await controller.loadPackage(
                    projectID: sourceRevision.projectID
                )
                guard currentPackage.manifest.headRevisionID == sourceRevision.revisionID,
                      let currentRevision = currentPackage.revisions.first(where: {
                          $0.manifest.revisionID == sourceRevision.revisionID
                      })
                else {
                    throw RoomAIRedesignModelFactoryError.staleSourceRevision
                }
                let currentCompanion = try await controller.redesignState(
                    sourceRevision: sourceRevision
                )
                guard let currentCompanion else {
                    throw RoomAIRedesignModelFactoryError.missingConfirmedOrientation
                }

                let permissions = try Self.permissions(
                    request.featureChoices,
                    displayToFeatureID: displayToFeatureID,
                    snapshot: currentRevision.payload.semanticSnapshot
                )
                let intent = RoomRedesignIntentV2(
                    request: request.brief.trimmingCharacters(in: .whitespacesAndNewlines),
                    scope: request.scope,
                    constraints: currentCompanion.redesignIntent?.constraints,
                    permissions: permissions
                )
                try intent.validate()
                try await controller.saveRedesignIntent(
                    intent,
                    sourceRevision: sourceRevision
                )
                guard let persistedCompanion = try await controller.redesignState(
                    sourceRevision: sourceRevision
                ) else {
                    throw RoomAIRedesignModelFactoryError.missingConfirmedOrientation
                }
                try RoomOrientationReadiness.requireEligible(
                    persistedCompanion,
                    expectedSourceRevision: sourceRevision,
                    operation: .aiExport
                )

                let boundEvidence = RoomCaptureBundleLibrary.boundEvidence(
                    forProject: sourceRevision.projectID,
                    expectedSourceRevision: sourceRevision
                )
                let replacements = await replacementRegistry.snapshot()
                let lease = try workspaceFactory.makeLease()
                do {
                    return try await Task.detached(priority: .userInitiated) {
                        let renderer = UIKitRoomAIRoomPackageDerivativeRenderer(
                            snapshot: currentRevision.payload.semanticSnapshot,
                            expectedSourceRevision: sourceRevision,
                            canonicalViewSources: [:]
                        )
                        let base = try await RoomAIRoomPackageMaterializer().materialize(
                            package: currentPackage,
                            sourceRevision: sourceRevision,
                            companion: persistedCompanion,
                            boundEvidence: boundEvidence,
                            derivativeRenderer: renderer,
                            profile: request.profile,
                            into: lease
                        )
                        return try RoomAIReplacementRegistry.merging(
                            replacements,
                            into: base,
                            leaseURL: lease
                        )
                    }.value
                } catch {
                    try? workspaceFactory.cleanup(workspaceURL: lease)
                    throw error
                }
            },
            packageService: RoomAIRoomPackageAppService(
                workspaceFactory: workspaceFactory
            ),
            disclosure: RoomAIDisclosureCoordinator(),
            concepts: conceptCoordinator,
            conceptContext: conceptContext,
            canonicalViewChoices: cameraIDs,
            packageIdentifier: { request in
                guard request.sourceRevision == sourceRevision else {
                    throw RoomAIRedesignModelFactoryError.staleSourceRevision
                }
                return try conceptPackageProvenance.packageIdentifier(
                    for: sourceRevision,
                    mint: mintPackageIdentifier
                )
            },
            persistValidatedSourcePackage: { archive in
                let binding = try conceptPackageProvenance.record(
                    archive,
                    expectedSourceRevision: sourceRevision,
                    currentCanonicalCameraIDs: cameraIDs
                )
                return .init(
                    expectedSourceRevision: sourceRevision,
                    currentCanonicalCameraIDs: cameraIDs,
                    validatedSourceAIRoomPackages: [binding]
                )
            },
            originalComparisonImageData: { requestedSource in
                guard requestedSource == sourceRevision else {
                    throw RoomAIRedesignModelFactoryError.staleSourceRevision
                }
                let currentBinding = try await controller.redesignSourceBinding(
                    projectID: requestedSource.projectID,
                    revisionID: requestedSource.revisionID
                )
                guard currentBinding == requestedSource else {
                    throw RoomAIRedesignModelFactoryError.staleSourceRevision
                }
                return try await controller.thumbnailData(
                    for: requestedSource.projectID,
                    expectedHeadRevisionID: requestedSource.revisionID
                )
            },
            registerReplacement: { targetID, url, requestedSource in
                try await replacementRegistry.register(
                    targetID: targetID,
                    sourceURL: url,
                    requestedSourceRevision: requestedSource
                )
            }
        )
        let model = RoomAIRedesignProductionModel(
            sourceRevision: sourceRevision,
            featureChoices: featureBindings.initialChoices,
            dependencies: dependencies
        )
        if let intent = companion.redesignIntent {
            model.brief = intent.request
            model.intent = Self.presentationScope(intent.scope)
        }
        return model
    }

    private struct FeatureBindings {
        var displayToFeatureID: [String: String]
        var initialChoices: [String: RoomAIChangeRequest]
    }

    private static func featureBindings(
        snapshot: RoomSemanticSnapshot,
        intent: RoomRedesignIntentV2?
    ) -> FeatureBindings {
        let elements = (snapshot.structuralElements + snapshot.objectElements)
            .sorted { $0.id < $1.id }
        let normalizedLabels = elements.map { element in
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? element.kind.capitalized : label
        }
        let labelCounts = Dictionary(grouping: normalizedLabels, by: { $0 })
            .mapValues(\.count)
        let existing = Dictionary(uniqueKeysWithValues: (intent?.permissions ?? []).map {
            ($0.featureID, $0.permission)
        })
        var map: [String: String] = [:]
        var choices: [String: RoomAIChangeRequest] = [:]
        for (element, label) in zip(elements, normalizedLabels) {
            let display = labelCounts[label] == 1 ? label : "\(label) · \(element.id)"
            map[display] = element.id
            choices[display] = presentationPermission(
                existing[element.id] ?? .preserve
            )
        }
        return FeatureBindings(
            displayToFeatureID: map,
            initialChoices: choices
        )
    }

    private static func permissions(
        _ choices: [String: RoomAIChangeRequest],
        displayToFeatureID: [String: String],
        snapshot: RoomSemanticSnapshot
    ) throws -> [RoomFeaturePermissionContract] {
        let knownIDs = Set(
            (snapshot.structuralElements + snapshot.objectElements).map(\.id)
        )
        var byID: [String: RoomFeatureRedesignPermission] = [:]
        for (display, choice) in choices {
            guard let featureID = displayToFeatureID[display],
                  knownIDs.contains(featureID)
            else {
                throw RoomAIRedesignModelFactoryError.staleSourceRevision
            }
            byID[featureID] = corePermission(choice)
        }
        return knownIDs.sorted().map {
            RoomFeaturePermissionContract(
                featureID: $0,
                permission: byID[$0] ?? .preserve
            )
        }
    }

    private static func corePermission(
        _ value: RoomAIChangeRequest
    ) -> RoomFeatureRedesignPermission {
        switch value {
        case .preserve: .preserve
        case .mayChange: .mayChange
        case .requestedChange: .requestedChange
        }
    }

    private static func presentationPermission(
        _ value: RoomFeatureRedesignPermission
    ) -> RoomAIChangeRequest {
        switch value {
        case .preserve: .preserve
        case .mayChange: .mayChange
        case .requestedChange: .requestedChange
        }
    }

    private static func presentationScope(_ value: RoomRedesignScope) -> String {
        switch value {
        case .stage: "Stage"
        case .renovate: "Renovate"
        case .reimagine: "Reimagine"
        }
    }
}

private enum RoomAIConceptPackageProvenanceError: Error, LocalizedError {
    case unsafeStorage
    case invalidBinding

    var errorDescription: String? {
        switch self {
        case .unsafeStorage:
            "Local AI package provenance storage is unsafe. Automatic Concept mapping remains unavailable."
        case .invalidBinding:
            "The finalized AI package could not establish a verified local Concept mapping capability."
        }
    }
}

/// App-owned capability storage for automatic Concept mappings. It never
/// writes into the immutable room package: one canonical manifest from the
/// first independently validated finalization mints a stable source-revision
/// capability, which later builds of that source must reuse.
final class RoomAIConceptPackageProvenanceRegistry {
    private static let schemaVersion = "roomscan-ai-concept-provenance-v1"
    private static let directoryVersion = "v1"
    private static let recordFilename = "binding.json"
    private static let aiReadyArchiveFilename = "ai-ready-package.zip"
    private static let stagePrefix = ".roomscan-ai-provenance-stage-"
    /// The Core manifest ceiling is 8 MiB; base64 record storage plus the
    /// fixed envelope remains safely below this fail-closed local bound.
    private static let maximumStoredBindingBytes = 16 * 1_024 * 1_024
    /// The retained archive is a private local source for a future explicit
    /// publication selection. It is bounded by the frozen Core AI-ready
    /// ceiling and never names its file URL in a model, journal, DTO, or UI.
    private static let maximumStoredAIReadyArchiveBytes =
        RoomPublicationTransportLimits.maximumAIReadyPackageBytes

    private struct StoredBinding: Codable, Equatable {
        var schemaVersion: String
        var sourceRevision: RoomRedesignSourceRevision
        var manifestSHA256: String
        var manifestData: Data
    }

    private let rootURL: URL
    private let sourcePackageRootURL: URL
    private let fileManager: FileManager
    private let copyAIReadyArchive: (URL, URL) throws -> Void
    private let beforeRecordWrite: (Data, URL) throws -> Void

    init(
        rootURL: URL,
        sourcePackageRootURL: URL,
        fileManager: FileManager = .default,
        copyAIReadyArchive: ((URL, URL) throws -> Void)? = nil,
        beforeRecordWrite: ((Data, URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.sourcePackageRootURL = sourcePackageRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.copyAIReadyArchive = copyAIReadyArchive ?? { [fileManager] source, destination in
            try fileManager.copyItem(at: source, to: destination)
        }
        self.beforeRecordWrite = beforeRecordWrite ?? { _, _ in }
    }

    func bindings(for sourceRevision: RoomRedesignSourceRevision) throws -> [RoomConceptValidatedSourcePackage] {
        guard let directory = try existingRecordDirectory(for: sourceRevision) else {
            return []
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        var recordURL: URL?
        for entry in entries {
            let name = entry.lastPathComponent
            if name == Self.recordFilename {
                try requireRegularFile(entry)
                guard recordURL == nil else {
                    throw RoomAIConceptPackageProvenanceError.unsafeStorage
                }
                recordURL = entry
            } else if name == Self.aiReadyArchiveFilename {
                try requireBoundedAIReadyArchiveFile(entry)
            } else if name.hasPrefix(Self.stagePrefix) {
                try removeOwnedStage(entry)
            } else {
                throw RoomAIConceptPackageProvenanceError.unsafeStorage
            }
        }
        guard let recordURL else { return [] }
        return [try loadBinding(at: recordURL, expectedSourceRevision: sourceRevision)]
    }

    /// Returns the exact canonical manifest bytes, not a reconstruction from
    /// parsed fields. These bytes are the authority carried in a professional
    /// working set for automatic Concept mapping eligibility.
    func canonicalManifestData(
        for sourceRevision: RoomRedesignSourceRevision
    ) throws -> [Data] {
        guard let directory = try existingRecordDirectory(for: sourceRevision) else {
            return []
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        var recordURL: URL?
        for entry in entries {
            let name = entry.lastPathComponent
            if name == Self.recordFilename {
                try requireRegularFile(entry)
                guard recordURL == nil else {
                    throw RoomAIConceptPackageProvenanceError.unsafeStorage
                }
                recordURL = entry
            } else if name == Self.aiReadyArchiveFilename {
                try requireBoundedAIReadyArchiveFile(entry)
            } else if name.hasPrefix(Self.stagePrefix) {
                try removeOwnedStage(entry)
            } else {
                throw RoomAIConceptPackageProvenanceError.unsafeStorage
            }
        }
        guard let recordURL else { return [] }
        return [try storedBinding(
            at: recordURL,
            expectedSourceRevision: sourceRevision
        ).manifestData]
    }

    /// Core supplies this exact snapshot only after full archive/package and
    /// companion validation. Recovered copies deliberately do not invoke this
    /// method, preserving the no-copy provenance rule.
    func installCanonical(
        _ snapshot: RoomProfessionalConceptSourcePackageProvenanceSnapshot
    ) throws {
        let validated = try snapshot.validatedSourcePackage()
        let sourceRevision = snapshot.sourceRevision
        let stored = StoredBinding(
            schemaVersion: Self.schemaVersion,
            sourceRevision: sourceRevision,
            manifestSHA256: snapshot.manifestSHA256,
            manifestData: snapshot.canonicalManifestData
        )
        guard validated.sourceRevision == sourceRevision,
              snapshot.manifestSHA256 == RoomSHA256.hexDigest(of: snapshot.canonicalManifestData)
        else {
            throw RoomAIConceptPackageProvenanceError.invalidBinding
        }
        let directory = try ensureRecordDirectory(for: sourceRevision)
        let recordURL = directory.appendingPathComponent(Self.recordFilename)
        if fileManager.fileExists(atPath: recordURL.path) {
            guard try storedBinding(
                at: recordURL,
                expectedSourceRevision: sourceRevision
            ) == stored else {
                throw RoomAIConceptPackageProvenanceError.invalidBinding
            }
            return
        }
        try writeOwnedRecord(try RoomRedesignCanonicalJSON.encode(stored), to: recordURL)
        guard try storedBinding(at: recordURL, expectedSourceRevision: sourceRevision) == stored else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    /// No identifier is committed until `record` receives a successful
    /// independently validated archive. A later build reloads the first
    /// persisted capability instead of minting a second package identity.
    func packageIdentifier(
        for sourceRevision: RoomRedesignSourceRevision,
        mint: () -> String
    ) throws -> String {
        if let binding = try bindings(for: sourceRevision).first {
            return binding.sourceAIRoomPackage.packageID
        }
        let identifier = mint()
        guard Self.isSafeStableIdentifier(identifier) else {
            throw RoomAIConceptPackageProvenanceError.invalidBinding
        }
        return identifier
    }

    func record(
        _ archive: RoomAIRoomPackageArchiveResult,
        expectedSourceRevision: RoomRedesignSourceRevision,
        currentCanonicalCameraIDs: [String]
    ) throws -> RoomConceptValidatedSourcePackage {
        try expectedSourceRevision.validate()
        let canonicalManifestData = try RoomAIRoomPackageBuilder.canonicalManifestData(archive.package)
        guard canonicalManifestData == archive.manifestData,
              archive.package.sourceRevision == expectedSourceRevision
        else {
            throw RoomAIConceptPackageProvenanceError.invalidBinding
        }
        let finalizedBinding = try RoomConceptValidatedSourcePackage(
            validatedManifestData: archive.manifestData
        )
        guard finalizedBinding.sourceRevision == expectedSourceRevision,
              exactCameraIDs(finalizedBinding.canonicalCameraIDs, currentCanonicalCameraIDs)
        else {
            throw RoomAIConceptPackageProvenanceError.invalidBinding
        }

        let directory = try ensureRecordDirectory(for: expectedSourceRevision)
        let recordURL = directory.appendingPathComponent(Self.recordFilename)
        if fileManager.fileExists(atPath: recordURL.path) {
            let existingStored = try storedBinding(
                at: recordURL,
                expectedSourceRevision: expectedSourceRevision
            )
            let existingBinding = try RoomConceptValidatedSourcePackage(
                validatedManifestData: existingStored.manifestData
            )
            guard existingBinding.sourceAIRoomPackage == finalizedBinding.sourceAIRoomPackage,
                  existingBinding.canonicalCameraIDs == finalizedBinding.canonicalCameraIDs
            else {
                throw RoomAIConceptPackageProvenanceError.invalidBinding
            }
            if archive.package.profile == .aiReady {
                // A legacy v1 binding did not retain archive bytes. Backfill
                // only when this independently finalized archive exactly
                // reproduces its pre-existing canonical provenance. A
                // different manifest cannot replace or silently rebind it.
                guard existingStored.manifestData == archive.manifestData else {
                    let retained = directory.appendingPathComponent(Self.aiReadyArchiveFilename)
                    if fileManager.fileExists(atPath: retained.path) {
                        throw RoomAIConceptPackageProvenanceError.invalidBinding
                    }
                    return existingBinding
                }
                _ = try retainAIReadyArchive(
                    archive,
                    expectedSourceRevision: expectedSourceRevision
                )
            }
            return existingBinding
        }

        let stored = StoredBinding(
            schemaVersion: Self.schemaVersion,
            sourceRevision: expectedSourceRevision,
            manifestSHA256: finalizedBinding.manifestSHA256,
            manifestData: archive.manifestData
        )
        let data = try RoomRedesignCanonicalJSON.encode(stored)
        let retainedByThisInvocation: Bool
        if archive.package.profile == .aiReady {
            retainedByThisInvocation = try retainAIReadyArchive(
                archive,
                expectedSourceRevision: expectedSourceRevision
            )
        } else {
            retainedByThisInvocation = false
        }
        // Retain first: a failed copy leaves no durable authority record, so
        // a later exact retry can repair it. If record promotion races/fails,
        // the retained sidecar is still unreferenced and harmless until this
        // same validated provenance is committed.
        do {
            try beforeRecordWrite(data, recordURL)
            try writeOwnedRecord(data, to: recordURL)
        } catch {
            if retainedByThisInvocation,
               !fileManager.fileExists(atPath: recordURL.path) {
                try removeOwnedAIReadyArchive(
                    at: directory.appendingPathComponent(Self.aiReadyArchiveFilename)
                )
            }
            throw error
        }
        return try loadBinding(at: recordURL, expectedSourceRevision: expectedSourceRevision)
    }

    /// Looks up and independently validates a private retained archive before
    /// handing a transient candidate to the publication factory. Any storage
    /// anomaly, stale source, profile mismatch, manifest mismatch, ZIP
    /// closure error, or missing archive becomes an honest unavailable state.
    /// The archive location never crosses this capability boundary except as
    /// an in-memory value consumed immediately by Core preparation.
    func publicationAIReadyPackageCandidate(
        for sourceRevision: RoomRedesignSourceRevision
    ) async -> RoomPublicationAIReadyPackageCandidate? {
        do {
            guard let directory = try existingRecordDirectory(for: sourceRevision) else {
                return nil
            }
            let recordURL = directory.appendingPathComponent(Self.recordFilename)
            let archiveURL = directory.appendingPathComponent(Self.aiReadyArchiveFilename)
            guard fileManager.fileExists(atPath: recordURL.path),
                  fileManager.fileExists(atPath: archiveURL.path)
            else { return nil }
            let stored = try storedBinding(
                at: recordURL,
                expectedSourceRevision: sourceRevision
            )
            try requireBoundedAIReadyArchiveFile(archiveURL)
            let verificationRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "RoomScanStudio-AIRedesignPublicationVerify-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: verificationRoot,
                withIntermediateDirectories: false
            )
            defer { try? fileManager.removeItem(at: verificationRoot) }
            let validation = try await RoomAIRoomPackageArchive.extractAndValidate(
                archiveURL: archiveURL,
                into: verificationRoot,
                expectedSourceRevision: sourceRevision,
                expectedProfile: .aiReady,
                limits: .init(
                    maxEntries: 4_096,
                    maxEntryBytes: Self.maximumStoredAIReadyArchiveBytes,
                    maxArchiveBytes: Self.maximumStoredAIReadyArchiveBytes
                )
            )
            let storedPackage = try RoomConceptValidatedSourcePackage(
                validatedManifestData: stored.manifestData
            )
            guard validation.package.sourceRevision == sourceRevision,
                  validation.package.profile == .aiReady,
                  validation.manifestData == stored.manifestData,
                  validation.package.packageID == storedPackage.sourceAIRoomPackage.packageID
            else { return nil }
            return .init(
                archiveURL: archiveURL,
                sourceRevision: sourceRevision,
                expectedPackageID: validation.package.packageID
            )
        } catch {
            return nil
        }
    }

    private func loadBinding(
        at url: URL,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) throws -> RoomConceptValidatedSourcePackage {
        let stored = try storedBinding(at: url, expectedSourceRevision: expectedSourceRevision)
        do {
            return try .init(validatedManifestData: stored.manifestData)
        } catch {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    private func storedBinding(
        at url: URL,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) throws -> StoredBinding {
        try requireBoundedBindingFile(url)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let stored: StoredBinding
        do {
            stored = try RoomJSONCoding.makeDecoder().decode(StoredBinding.self, from: data)
        } catch {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        guard stored.schemaVersion == Self.schemaVersion,
              stored.sourceRevision == expectedSourceRevision,
              stored.manifestSHA256 == RoomSHA256.hexDigest(of: stored.manifestData),
              try RoomRedesignCanonicalJSON.encode(stored) == data
        else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        let binding: RoomConceptValidatedSourcePackage
        do {
            binding = try .init(validatedManifestData: stored.manifestData)
        } catch {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        guard binding.sourceRevision == expectedSourceRevision,
              binding.manifestSHA256 == stored.manifestSHA256
        else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        return stored
    }

    private func ensureRecordDirectory(
        for sourceRevision: RoomRedesignSourceRevision
    ) throws -> URL {
        try validateRootIsOutsideSourcePackage()
        var directory = rootURL
        try ensureOwnedDirectory(directory)
        for component in try recordPathComponents(for: sourceRevision) {
            directory.appendPathComponent(component, isDirectory: true)
            try ensureOwnedDirectory(directory)
        }
        return directory
    }

    private func existingRecordDirectory(
        for sourceRevision: RoomRedesignSourceRevision
    ) throws -> URL? {
        try validateRootIsOutsideSourcePackage()
        guard fileManager.fileExists(atPath: rootURL.path) else { return nil }
        var directory = rootURL
        try requireDirectory(directory)
        for component in try recordPathComponents(for: sourceRevision) {
            directory.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { return nil }
            try requireDirectory(directory)
        }
        return directory
    }

    private func recordPathComponents(
        for sourceRevision: RoomRedesignSourceRevision
    ) throws -> [String] {
        try sourceRevision.validate()
        let components = [
            Self.directoryVersion,
            sourceRevision.projectID,
            sourceRevision.revisionID,
            sourceRevision.revisionManifestSHA256,
        ]
        guard components.allSatisfy({ Self.isSafeStableIdentifier($0) }) else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        return components
    }

    private func validateRootIsOutsideSourcePackage() throws {
        // Check every extant component before any create/read/write. A lexical
        // sibling such as `root/escape/AIRedesignProvenance` must not follow
        // an `escape -> root/Projects` ancestor into immutable source storage.
        try requireNoSymbolicLinkInExistingAncestors(of: rootURL)
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = sourcePackageRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard rootPath != sourcePath,
              !rootPath.hasPrefix(sourcePath + "/")
        else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    private func ensureOwnedDirectory(_ url: URL) throws {
        try requireNoSymbolicLinkInExistingAncestors(of: url)
        if fileManager.fileExists(atPath: url.path) {
            try requireDirectory(url)
            return
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try requireDirectory(url)
    }

    private func requireDirectory(_ url: URL) throws {
        try requireNoSymbolicLinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        try requireNoSymbolicLinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    private func requireBoundedBindingFile(_ url: URL) throws {
        try requireNoSymbolicLinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= Self.maximumStoredBindingBytes
        else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    private func requireBoundedAIReadyArchiveFile(_ url: URL) throws {
        try requireNoSymbolicLinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              UInt64(byteCount) <= Self.maximumStoredAIReadyArchiveBytes
        else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    /// Copies only an already-finalized local `aiReady` archive into the
    /// app-owned provenance root. The source URL is never recorded. A later
    /// publication request independently validates the retained bytes before
    /// it becomes a Core asset, so a failed/tampered copy can only disable
    /// this optional download rather than broaden publication disclosure.
    private func retainAIReadyArchive(
        _ archive: RoomAIRoomPackageArchiveResult,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) throws -> Bool {
        guard archive.package.profile == .aiReady,
              archive.package.sourceRevision == expectedSourceRevision
        else { throw RoomAIConceptPackageProvenanceError.invalidBinding }
        try requireBoundedAIReadyArchiveFile(archive.archiveURL)
        let expectedDigest = archive.receipt.archiveSHA256
        let expectedByteCount = archive.receipt.archiveByteCount
        let sourceValues = try archive.archiveURL.resourceValues(forKeys: [.fileSizeKey])
        guard expectedByteCount > 0,
              expectedByteCount <= Self.maximumStoredAIReadyArchiveBytes,
              sourceValues.fileSize.map(UInt64.init) == expectedByteCount,
              try RoomSHA256.hexDigest(ofFile: archive.archiveURL) == expectedDigest
        else {
            throw RoomAIConceptPackageProvenanceError.invalidBinding
        }
        let directory = try ensureRecordDirectory(for: expectedSourceRevision)
        let destination = directory.appendingPathComponent(Self.aiReadyArchiveFilename)
        if fileManager.fileExists(atPath: destination.path) {
            // Do not replace an existing private artifact. Exact bytes must
            // match the same independently finalized receipt; otherwise the
            // provenance is inconsistent and publication fails closed.
            try requireBoundedAIReadyArchiveFile(destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize.map(UInt64.init) == expectedByteCount,
                  try RoomSHA256.hexDigest(ofFile: destination) == expectedDigest
            else { throw RoomAIConceptPackageProvenanceError.invalidBinding }
            return false
        }
        let stage = directory.appendingPathComponent(
            Self.stagePrefix + UUID().uuidString.lowercased()
        )
        defer { try? removeOwnedStage(stage) }
        try copyAIReadyArchive(archive.archiveURL, stage)
        try requireBoundedAIReadyArchiveFile(stage)
        guard expectedByteCount > 0,
              expectedByteCount <= Self.maximumStoredAIReadyArchiveBytes,
              try RoomSHA256.hexDigest(ofFile: stage) == expectedDigest
        else {
            throw RoomAIConceptPackageProvenanceError.invalidBinding
        }
        do {
            try fileManager.moveItem(at: stage, to: destination)
        } catch {
            guard fileManager.fileExists(atPath: destination.path) else { throw error }
            try requireBoundedAIReadyArchiveFile(destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize.map(UInt64.init) == expectedByteCount,
                  try RoomSHA256.hexDigest(ofFile: destination) == expectedDigest
            else { throw RoomAIConceptPackageProvenanceError.invalidBinding }
            return false
        }
        try requireBoundedAIReadyArchiveFile(destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize.map(UInt64.init) == expectedByteCount,
              try RoomSHA256.hexDigest(ofFile: destination) == expectedDigest
        else { throw RoomAIConceptPackageProvenanceError.invalidBinding }
        return true
    }

    private func removeOwnedAIReadyArchive(at url: URL) throws {
        guard url.lastPathComponent == Self.aiReadyArchiveFilename else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        try requireBoundedAIReadyArchiveFile(url)
        try fileManager.removeItem(at: url)
    }

    private func writeOwnedRecord(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try requireNoSymbolicLinkInExistingAncestors(of: directory)
        try requireDirectory(directory)
        let stage = directory.appendingPathComponent(
            Self.stagePrefix + UUID().uuidString.lowercased()
        )
        defer { try? removeOwnedStage(stage) }
        try data.write(to: stage, options: [.withoutOverwriting])
        try requireRegularFile(stage)
        guard try Data(contentsOf: stage, options: [.mappedIfSafe]) == data else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        do {
            try fileManager.moveItem(at: stage, to: destination)
        } catch {
            guard fileManager.fileExists(atPath: destination.path) else { throw error }
            try requireRegularFile(destination)
            guard try Data(contentsOf: destination, options: [.mappedIfSafe]) == data else {
                throw RoomAIConceptPackageProvenanceError.unsafeStorage
            }
            return
        }
        try requireRegularFile(destination)
        guard try Data(contentsOf: destination, options: [.mappedIfSafe]) == data else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
    }

    private func removeOwnedStage(_ url: URL) throws {
        guard url.lastPathComponent.hasPrefix(Self.stagePrefix) else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        try requireNoSymbolicLinkInExistingAncestors(of: url)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try requireRegularFile(url)
        try fileManager.removeItem(at: url)
    }

    private func exactCameraIDs(_ packageCameraIDs: [String], _ currentCameraIDs: [String]) -> Bool {
        guard packageCameraIDs.count == 6,
              currentCameraIDs.count == 6,
              Set(packageCameraIDs).count == packageCameraIDs.count,
              Set(currentCameraIDs).count == currentCameraIDs.count,
              packageCameraIDs.allSatisfy({ Self.isSafeStableIdentifier($0) }),
              currentCameraIDs.allSatisfy({ Self.isSafeStableIdentifier($0) })
        else {
            return false
        }
        return Set(packageCameraIDs) == Set(currentCameraIDs)
    }

    private static func isSafeStableIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil
    }

    /// `FileManager.fileExists` follows symlinks, so inspect every existing
    /// path component with `destinationOfSymbolicLink` first. A missing
    /// component ends the walk; no deeper component can exist without it.
    private func requireNoSymbolicLinkInExistingAncestors(of url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw RoomAIConceptPackageProvenanceError.unsafeStorage
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: false)
            if (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw RoomAIConceptPackageProvenanceError.unsafeStorage
            }
            guard fileManager.fileExists(atPath: current.path) else { return }
        }
    }
}

private struct RoomAIReplacement: Sendable {
    let targetID: String
    let candidate: RoomAIReferenceImageCandidate
    let image: RoomAISanitizedImage
    let advisories: [RoomAISensitiveContentAdvisory]
}

/// A model-scoped in-memory registry. Security-scoped source URLs and source
/// bytes are never retained; only a fresh, metadata-free JPEG and advisory
/// result survive until the next exact package preparation.
private actor RoomAIReplacementRegistry {
    private let sourceRevision: RoomRedesignSourceRevision
    private var replacementsByTargetID: [String: RoomAIReplacement] = [:]

    init(sourceRevision: RoomRedesignSourceRevision) {
        self.sourceRevision = sourceRevision
    }

    func register(
        targetID: String,
        sourceURL: URL,
        requestedSourceRevision: RoomRedesignSourceRevision
    ) async throws -> String {
        guard requestedSourceRevision == sourceRevision,
              !targetID.isEmpty else {
            throw RoomAIRedesignModelFactoryError.staleSourceRevision
        }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= RoomAIImageSanitizationLimits.default.maximumInputBytes
        else {
            throw RoomAIRedesignModelFactoryError.unsafeReplacement
        }
        let bytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard bytes.count == byteCount else {
            throw RoomAIRedesignModelFactoryError.unsafeReplacement
        }
        let image = try RoomAIImageSanitizer.sanitizeReferenceJPEG(
            bytes,
            declaredFilename: sourceURL.lastPathComponent
        )
        let advisories = (try? await RoomAISensitiveContentAnalyzer.analyze(image))
            ?? RoomAISensitiveContentAnalyzer.advisories(
                faceCount: 0,
                humanCount: 0,
                recognizedText: []
            )
        let identityData = Data(
            "\(sourceRevision.projectID)\n\(sourceRevision.revisionID)\n\(targetID)\n\(RoomSHA256.hexDigest(of: image.data))"
                .utf8
        )
        let candidateID = "replacement-\(RoomSHA256.hexDigest(of: identityData).prefix(24))"
        let candidate = RoomAIReferenceImageCandidate(
            evidenceID: candidateID,
            sourceRevision: sourceRevision,
            capturedAt: Date(),
            sharpness: try Self.sharpness(image.data)
        )
        replacementsByTargetID[targetID] = RoomAIReplacement(
            targetID: targetID,
            candidate: candidate,
            image: image,
            advisories: advisories
        )
        return candidateID
    }

    func snapshot() -> [RoomAIReplacement] {
        replacementsByTargetID.values.sorted {
            $0.candidate.evidenceID < $1.candidate.evidenceID
        }
    }

    nonisolated static func merging(
        _ replacements: [RoomAIReplacement],
        into base: RoomAIRoomPackageMaterialization,
        leaseURL: URL
    ) throws -> RoomAIRoomPackageMaterialization {
        guard !replacements.isEmpty else { return base }
        var artifacts = base.artifacts
        var candidates = base.referenceCandidates
        var disclosure = base.referenceDisclosure
        for replacement in replacements {
            let id = replacement.candidate.evidenceID
            let relativePath = "staged-references/\(id).jpg"
            let destination = leaseURL.appendingPathComponent(relativePath)
            try replacement.image.data.write(
                to: destination,
                options: [.withoutOverwriting]
            )
            artifacts.append(.init(
                artifactID: id,
                sourceURL: destination,
                relativePath: relativePath,
                mediaType: "image/jpeg"
            ))
            candidates.append(replacement.candidate)
            disclosure[id] = .init(
                byteCount: UInt64(replacement.image.data.count),
                mediaType: "image/jpeg",
                advisories: replacement.advisories
            )
        }
        return RoomAIRoomPackageMaterialization(
            context: base.context,
            profile: base.profile,
            artifacts: artifacts,
            referenceCandidates: candidates,
            qualityCarrier: base.qualityCarrier,
            rawRGBIDs: base.rawRGBIDs,
            rawDepthIDs: base.rawDepthIDs,
            rawConfidenceIDs: base.rawConfidenceIDs,
            diagnosticIDs: base.diagnosticIDs,
            referenceDisclosure: disclosure,
            rawImageDisclosure: base.rawImageDisclosure,
            sourceWorkspaceURL: base.sourceWorkspaceURL
        )
    }

    nonisolated private static func sharpness(_ data: Data) throws -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RoomAIRedesignModelFactoryError.unsafeReplacement
        }
        let width = min(image.width, 512)
        let height = min(image.height, 512)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard width > 0,
              height > 0,
              let context = CGContext(
                  data: &rgba,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw RoomAIRedesignModelFactoryError.unsafeReplacement
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RoomMeshFrameAnalysis.luminanceSharpness(
            rgba: rgba,
            width: width,
            height: height
        )
    }
}

enum RoomAIRedesignRootResolver {
    struct Roots {
        let concepts: URL
        let importScratch: URL
    }

    static func resolve(
        arguments: [String],
        projectRootURL: URL,
        fileManager: FileManager
    ) -> Roots {
        if arguments.contains("--ui-testing"),
           arguments.contains("--reset-local-store") {
            let temporaryRoot = fileManager.temporaryDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let suffix = String(ProcessInfo.processInfo.processIdentifier)
            return Roots(
                concepts: temporaryRoot.appendingPathComponent(
                    "RoomScanStudio-UI-Testing-ConceptSets-\(suffix)",
                    isDirectory: true
                ),
                importScratch: temporaryRoot.appendingPathComponent(
                    "RoomScanStudio-UI-Testing-ConceptImportScratch-\(suffix)",
                    isDirectory: true
                )
            )
        }
        let appRoot = projectRootURL.deletingLastPathComponent()
        return Roots(
            concepts: appRoot.appendingPathComponent(
                "ConceptSets",
                isDirectory: true
            ),
            importScratch: appRoot.appendingPathComponent(
                "ConceptImportScratch",
                isDirectory: true
            )
        )
    }
}
