import Foundation
import RoomScanCore

/// App-side, offline bridge for the Core package writer.  Callers first make
/// immutable source/derivative files in a private export lease, then this
/// service builds a complete ledger from that frozen materialization.  It has
/// deliberately no account, provider, or network dependency.
struct RoomAIRoomPackageAppArtifact: Sendable, Equatable {
    let artifactID: String
    let sourceURL: URL
    let relativePath: String
    let mediaType: String
}

struct RoomAIRoomPackageMaterialization: Sendable, Equatable {
    let context: RoomAIRoomPackageReadyContext
    let profile: RoomAIRoomPackageProfile
    let artifacts: [RoomAIRoomPackageAppArtifact]
    let referenceCandidates: [RoomAIReferenceImageCandidate]
    let qualityCarrier: RoomQualityReportCarrierV1?

    /// Complete-only raw IDs are merely accounted for.  The app must place
    /// their bytes in `artifacts` only after a fresh disclosure approval.
    let rawRGBIDs: [String]
    let rawDepthIDs: [String]
    let rawConfidenceIDs: [String]
    let diagnosticIDs: [String]
    let referenceDisclosure: [String: RoomAIReferenceImageDisclosure]
    let rawImageDisclosure: [String: RoomAIReferenceImageDisclosure]
    /// A factory-owned staging lease created by the materializer.  Once its
    /// bytes have been copied into the final export lease it must be removed.
    let sourceWorkspaceURL: URL?

    init(
        context: RoomAIRoomPackageReadyContext,
        profile: RoomAIRoomPackageProfile,
        artifacts: [RoomAIRoomPackageAppArtifact],
        referenceCandidates: [RoomAIReferenceImageCandidate] = [],
        qualityCarrier: RoomQualityReportCarrierV1? = nil,
        rawRGBIDs: [String] = [], rawDepthIDs: [String] = [],
        rawConfidenceIDs: [String] = [], diagnosticIDs: [String] = [],
        referenceDisclosure: [String: RoomAIReferenceImageDisclosure] = [:],
        rawImageDisclosure: [String: RoomAIReferenceImageDisclosure] = [:],
        sourceWorkspaceURL: URL? = nil
    ) {
        self.context = context; self.profile = profile; self.artifacts = artifacts
        self.referenceCandidates = referenceCandidates; self.qualityCarrier = qualityCarrier
        self.rawRGBIDs = rawRGBIDs; self.rawDepthIDs = rawDepthIDs
        self.rawConfidenceIDs = rawConfidenceIDs; self.diagnosticIDs = diagnosticIDs
        self.referenceDisclosure = referenceDisclosure
        self.rawImageDisclosure = rawImageDisclosure
        self.sourceWorkspaceURL = sourceWorkspaceURL
    }
}

struct RoomAIReferenceImageDisclosure: Sendable, Equatable {
    let byteCount: UInt64
    let mediaType: String
    let advisories: [RoomAISensitiveContentAdvisory]
}

struct RoomAIRoomPackagePreparedDraft: Sendable, Equatable {
    let preparation: RoomAIRoomPackagePreparation
    let disclosureDraft: RoomAIDisclosureDraft
    /// Bounded, metadata-free, local display derivatives keyed by the exact
    /// selected evidence IDs reviewed in `disclosureDraft`.
    let selectedImagePreviewData: [String: Data]
    let workspaceURL: URL
}

@MainActor
protocol RoomAIRoomPackageServicing: AnyObject {
    func prepare(
        materialization: RoomAIRoomPackageMaterialization,
        excludedReferenceIDs: Set<String>,
        replacementReferenceIDs: Set<String>,
        packageID: String
    ) async throws -> RoomAIRoomPackagePreparedDraft

    func finalize(
        _ draft: RoomAIRoomPackagePreparedDraft,
        disclosureReview: RoomDisclosureReview
    ) async throws -> RoomAIRoomPackageArchiveResult

    func cleanupLease(_ lease: URL) throws
}

enum RoomAIRoomPackageAppServiceError: Error, Equatable {
    case duplicateArtifactID
    case missingRequiredArtifact(String)
    case unsafeArtifactPath(String)
    case rawEvidenceNeedsApproval
    case stalePreparation
}

/// All expensive image and ZIP work is invoked from an async task, not a
/// capture callback or SwiftUI body.  The returned lease stays owned by the
/// workspace factory until a typed share outcome requests cleanup.
@MainActor
final class RoomAIRoomPackageAppService {
    private let workspaceFactory: RoomExportWorkspaceFactory
    private let fileManager: FileManager

    init(workspaceFactory: RoomExportWorkspaceFactory, fileManager: FileManager = .default) {
        self.workspaceFactory = workspaceFactory
        self.fileManager = fileManager
    }

    func prepare(
        materialization: RoomAIRoomPackageMaterialization,
        excludedReferenceIDs: Set<String> = [],
        replacementReferenceIDs: Set<String> = [],
        packageID: String = "ai-room-package"
    ) async throws -> RoomAIRoomPackagePreparedDraft {
        let lease = try workspaceFactory.makeLease()
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await Self.prepareOffMain(
                    materialization: materialization,
                    excludedReferenceIDs: excludedReferenceIDs,
                    replacementReferenceIDs: replacementReferenceIDs,
                    packageID: packageID,
                    lease: lease
                )
            }.value
            if let staging = materialization.sourceWorkspaceURL, staging != lease {
                try workspaceFactory.cleanup(workspaceURL: staging)
            }
            return prepared
        } catch {
            try? workspaceFactory.cleanup(workspaceURL: lease)
            if let staging = materialization.sourceWorkspaceURL, staging != lease {
                try? workspaceFactory.cleanup(workspaceURL: staging)
            }
            throw error
        }
    }

    nonisolated private static func prepareOffMain(
        materialization: RoomAIRoomPackageMaterialization,
        excludedReferenceIDs: Set<String>, replacementReferenceIDs: Set<String>,
        packageID: String, lease: URL
    ) async throws -> RoomAIRoomPackagePreparedDraft {
            let selection = try selectReferences(
                materialization.referenceCandidates,
                source: materialization.context.sourceRevision,
                profile: materialization.profile,
                excluded: excludedReferenceIDs,
                replacements: replacementReferenceIDs
            )
            let inventory = RoomAIArtifactInventory(
                referenceImageIDs: selection.selected.map(\.evidenceID),
                meshIDs: ids(in: materialization.artifacts, pathPrefix: "geometry/", artifactIDPrefix: "mesh-", mediaTypes: ["model/vnd.usdz+zip", "model/gltf-binary", "model/obj", "text/plain", "application/octet-stream"]),
                textureIDs: ids(in: materialization.artifacts, pathPrefix: "appearance/textures/", artifactIDPrefix: "texture-", mediaTypes: ["image/png"]),
                rawRGBIDs: materialization.profile == .complete ? materialization.rawRGBIDs : [],
                rawDepthIDs: materialization.profile == .complete ? materialization.rawDepthIDs : [],
                rawConfidenceIDs: materialization.profile == .complete ? materialization.rawConfidenceIDs : [],
                diagnosticIDs: materialization.profile == .complete ? materialization.diagnosticIDs : []
            )
            let plan = try RoomAIArtifactPlanner.makePlan(profile: materialization.profile, context: materialization.context, inventory: inventory)
            let inputs = try await makeInputs(plan: plan, materialization: materialization, selection: selection, lease: lease)
            let preparation = try await RoomAIRoomPackageBuilder.prepare(packageID: packageID, plan: plan, inputs: inputs)
            let referenceImages = selection.selected.map {
                let disclosure = materialization.referenceDisclosure[$0.evidenceID]
                return RoomAIDisclosureSelectedImage(
                    imageID: $0.evidenceID,
                    displayName: $0.evidenceID,
                    mediaType: disclosure?.mediaType ?? "image/jpeg",
                    byteCount: disclosure?.byteCount ?? 1,
                    advisories: disclosure?.advisories ?? [],
                    replacesImageID: replacementReferenceIDs.contains($0.evidenceID) ? "replacement" : nil
                )
            }
            let rawImages = try preparation.artifacts
                .filter { $0.artifactClass == .rawRGB && $0.disposition == .included }
                .sorted { $0.artifactID < $1.artifactID }
                .map { artifact in
                    guard let disclosure = materialization.rawImageDisclosure[artifact.artifactID]
                    else {
                        throw RoomAIRoomPackageAppServiceError.missingRequiredArtifact(
                            artifact.artifactID
                        )
                    }
                    let stableFrameID = artifact.artifactID.hasPrefix("raw-rgb-")
                        ? String(artifact.artifactID.dropFirst("raw-rgb-".count))
                        : artifact.artifactID
                    return RoomAIDisclosureSelectedImage(
                        imageID: artifact.artifactID,
                        displayName: "Original capture frame \(stableFrameID)",
                        mediaType: disclosure.mediaType,
                        byteCount: disclosure.byteCount,
                        advisories: disclosure.advisories,
                        replacesImageID: nil,
                        isRawEvidence: true
                    )
                }
            let draft = RoomAIDisclosureDraft(
                sourceRevision: preparation.sourceRevision, profile: preparation.profile,
                artifactPlanSHA256: preparation.artifactPlanSHA256, selectionSHA256: preparation.selectionSHA256,
                selectedImages: referenceImages + rawImages,
                artifactInventory: preparation.artifacts.map { .init(artifactID: $0.artifactID, artifactClass: $0.artifactClass, disposition: $0.disposition, reasonCode: $0.reasonCode) },
                estimatedPackageByteCount: preparation.artifacts.compactMap(\.byteCount).reduce(0, +),
                qualityWarnings: materialization.qualityCarrier == nil ? ["Quality report carrier unavailable."] : [],
                includesRawEvidence: preparation.artifacts.contains { $0.artifactClass.isAIRawEvidence && $0.disposition == .included }, preciseGPSExcluded: true
            )
            var previews = try Dictionary(uniqueKeysWithValues: selection.selected.map { selected in
                let slotID = "reference-image-\(selected.evidenceID)"
                guard let source = preparation.includedSources.first(where: {
                    $0.slot.artifactID == slotID
                }) else {
                    throw RoomAIRoomPackageAppServiceError.missingRequiredArtifact(slotID)
                }
                let bytes = try Data(contentsOf: source.sourceURL, options: [.mappedIfSafe])
                return (
                    selected.evidenceID,
                    try RoomAIImageSanitizer.makeReviewThumbnailJPEG(bytes)
                )
            })
            for source in preparation.includedSources
                where source.slot.artifactClass == .rawRGB {
                let bytes = try Data(contentsOf: source.sourceURL, options: [.mappedIfSafe])
                previews[source.slot.artifactID] = try RoomAIImageSanitizer
                    .makeReviewThumbnailJPEG(bytes)
            }
            return .init(
                preparation: preparation,
                disclosureDraft: draft,
                selectedImagePreviewData: previews,
                workspaceURL: lease
            )
    }

    func finalize(
        _ draft: RoomAIRoomPackagePreparedDraft,
        disclosureReview: RoomDisclosureReview
    ) async throws -> RoomAIRoomPackageArchiveResult {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let archiveURL = draft.workspaceURL.appendingPathComponent("ai-room-package.zip")
                let archiveWorkspace = draft.workspaceURL.appendingPathComponent("archive-staging", isDirectory: true)
                try FileManager.default.createDirectory(at: archiveWorkspace, withIntermediateDirectories: false)
                do {
                    let result = try await RoomAIRoomPackageArchive.build(preparation: draft.preparation, disclosureReview: disclosureReview, archiveURL: archiveURL, workspaceURL: archiveWorkspace)
                    try FileManager.default.removeItem(at: archiveWorkspace)
                    return result
                } catch {
                    try? FileManager.default.removeItem(at: archiveWorkspace)
                    throw error
                }
            }.value
        } catch {
            // No archive may outlive a failed/disallowed finalization.  The
            // outer directory is factory-owned and therefore safe to clean.
            try? workspaceFactory.cleanup(workspaceURL: draft.workspaceURL)
            throw error
        }
    }

    func cleanupLease(_ lease: URL) throws { try workspaceFactory.cleanup(workspaceURL: lease) }

    nonisolated private static func makeInputs(plan: RoomAIArtifactPlan, materialization: RoomAIRoomPackageMaterialization, selection: RoomAIReferenceImageSelection, lease: URL) async throws -> [RoomAIArtifactBuildInput] {
        var copied: [RoomAIRoomPackageAppArtifact] = []
        for artifact in materialization.artifacts {
            try validate(artifact)
            let bytes = try Data(contentsOf: artifact.sourceURL, options: [.mappedIfSafe])
            let safeBytes: Data
            if selection.selected.contains(where: { $0.evidenceID == artifact.artifactID }) {
                // Every outbound capture image crosses the metadata-stripping
                // boundary after selection, never by copying original bytes.
                let sanitized = try RoomAIImageSanitizer.sanitize(bytes, declaredFilename: artifact.sourceURL.lastPathComponent)
                guard sanitized.mediaType == "image/jpeg" else { throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(artifact.relativePath) }
                safeBytes = sanitized.data
            } else {
                safeBytes = bytes
            }
            let copiedURL = try write(safeBytes, relativePath: artifact.relativePath, in: lease)
            copied.append(.init(artifactID: artifact.artifactID, sourceURL: copiedURL, relativePath: artifact.relativePath, mediaType: artifact.mediaType))
        }
        var byID = Dictionary(uniqueKeysWithValues: copied.map { ($0.artifactID, $0) })
        guard byID.count == materialization.artifacts.count else { throw RoomAIRoomPackageAppServiceError.duplicateArtifactID }
        for selected in selection.selected {
            guard let original = byID[selected.evidenceID] else { continue }
            let slotID = "reference-image-\(selected.evidenceID)"
            byID[slotID] = .init(artifactID: slotID, sourceURL: original.sourceURL, relativePath: "references/\(selected.evidenceID).jpg", mediaType: "image/jpeg")
        }
        let instructions = try RoomAIRoomPackageBuilder.makeProviderInstructions(context: materialization.context, plan: plan, selectedReferenceImageIDs: selection.selected.map(\.evidenceID), qualityCarrier: materialization.qualityCarrier)
        for file in instructions.files {
            let url = try write(file.data, relativePath: file.relativePath, in: lease)
            byID[file.artifactID] = .init(artifactID: file.artifactID, sourceURL: url, relativePath: file.relativePath, mediaType: "text/plain")
        }
        if let carrier = materialization.qualityCarrier {
            let bytes = try RoomAIRoomPackageBuilder.validatedQualityCarrierBytes(carrier, boundTo: materialization.context.sourceRevision)
            let url = try write(bytes, relativePath: "quality/quality-report-carrier.json", in: lease)
            byID["quality-report-carrier"] = .init(artifactID: "quality-report-carrier", sourceURL: url, relativePath: "quality/quality-report-carrier.json", mediaType: "application/json")
        }
        return try plan.slots.map { slot in
            if let artifact = byID[slot.artifactID] {
                try validate(artifact)
                return .included(slot: slot, sourceURL: artifact.sourceURL, relativePath: artifact.relativePath, mediaType: artifact.mediaType)
            }
            if required(slot.artifactClass) { throw RoomAIRoomPackageAppServiceError.missingRequiredArtifact(slot.artifactID) }
            return .unavailable(slot: slot, reasonCode: "not-available")
        }
    }

    nonisolated static func selectReferences(_ candidates: [RoomAIReferenceImageCandidate], source: RoomRedesignSourceRevision, profile: RoomAIRoomPackageProfile, excluded: Set<String>, replacements: Set<String>) throws -> RoomAIReferenceImageSelection {
        let filtered = candidates.filter { !excluded.contains($0.evidenceID) }
        // Replacements are expected to be bound candidates supplied by the UI;
        // accepting an unknown replacement would silently defeat review.
        guard replacements.isSubset(of: Set(filtered.map(\.evidenceID))) else {
            throw RoomAIRoomPackageAppServiceError.stalePreparation
        }
        let ranked = try RoomAIReferenceImageSelector.select(
            candidates: filtered,
            sourceRevision: source,
            profile: profile
        )
        let rankedBound = ranked.selected + ranked.skipped
        let forced = rankedBound.filter { replacements.contains($0.evidenceID) }
        let limit = profile == .aiReady
            ? RoomAIReferenceImageSelector.aiReadyLimit
            : RoomAIReferenceImageSelector.completeLimit
        guard forced.count == replacements.count, forced.count <= limit else {
            throw RoomAIRoomPackageAppServiceError.stalePreparation
        }
        let nonReplacement = rankedBound.filter { !replacements.contains($0.evidenceID) }
        let selected = forced + nonReplacement.prefix(limit - forced.count)
        let selectedIDs = Set(selected.map(\.evidenceID))
        return RoomAIReferenceImageSelection(
            selected: Array(selected),
            skipped: rankedBound.filter { !selectedIDs.contains($0.evidenceID) },
            unavailable: ranked.unavailable
        )
    }

    nonisolated private static func write(_ data: Data, relativePath: String, in lease: URL) throws -> URL {
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else { throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(relativePath) }
        let url = lease.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.withoutOverwriting])
        return url
    }
    nonisolated private static func validate(_ artifact: RoomAIRoomPackageAppArtifact) throws {
        guard !artifact.relativePath.contains(".."), !artifact.relativePath.hasPrefix("/"), !artifact.relativePath.lowercased().contains("gps"), !artifact.relativePath.lowercased().contains("world-map") else { throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(artifact.relativePath) }
    }
    nonisolated private static func required(_ artifactClass: RoomRedesignArtifactClass) -> Bool { [.normalizedSemantics, .revisionLineage, .orientation, .floorPlan, .canonicalView, .roomBrief, .redesignIntent, .providerInstructions].contains(artifactClass) }
    nonisolated private static func ids(
        in artifacts: [RoomAIRoomPackageAppArtifact],
        pathPrefix: String,
        artifactIDPrefix: String,
        mediaTypes: Set<String>
    ) -> [String] {
        artifacts.compactMap { artifact in
            guard artifact.relativePath.hasPrefix(pathPrefix),
                  mediaTypes.contains(artifact.mediaType),
                  artifact.artifactID.hasPrefix(artifactIDPrefix)
            else { return nil }
            return String(artifact.artifactID.dropFirst(artifactIDPrefix.count))
        }.sorted()
    }
}

extension RoomAIRoomPackageAppService: RoomAIRoomPackageServicing {}

// Focused pure seams keep the policy testable without a capture session.
extension RoomAIRoomPackageAppService {
    static func selectionForTesting(candidates: [String], excluded: Set<String>, replacement: String) throws -> [String] {
        guard !excluded.contains(replacement) else { throw RoomAIRoomPackageAppServiceError.stalePreparation }
        return (candidates.filter { !excluded.contains($0) } + (candidates.contains(replacement) ? [] : [replacement])).sorted()
    }
    static func makePlanForTesting(profile: RoomAIRoomPackageProfile) throws -> RoomAIArtifactPlan {
        let source = RoomRedesignSourceRevision(projectID: "project-001", revisionID: "revision-001", coordinateSpaceEpochID: "epoch-001", packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue, semanticSHA256: String(repeating: "1", count: 64), revisionManifestSHA256: String(repeating: "2", count: 64))
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(sourceRevision: source, input: .init(source: .confirmed, confidence: 1, entryPositionMeters: .init(x: 0, y: 0, z: -1), inwardDirection: .init(x: 0, y: 0, z: 1), roomBounds: .init(minimum: .init(x: -1, y: 0, z: -1), maximum: .init(x: 1, y: 2, z: 1)), referenceWallFeatureID: "wall-001"))
        let companion = RoomLocalRedesignExtensionV2(sourceRevision: source, orientation: orientation, redesignIntent: .init(request: "Make it calm.", scope: .stage, constraints: nil, permissions: []), propertyMembership: nil, conceptMetadata: [])
        let context = try RoomAIRoomPackageReadiness.requireEligible(sourceRevision: source, companion: companion)
        return try RoomAIArtifactPlanner.makePlan(profile: profile, context: context, inventory: .init())
    }
}
