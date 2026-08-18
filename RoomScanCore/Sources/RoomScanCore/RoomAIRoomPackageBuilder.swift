import Foundation

public enum RoomAIProviderInstructionProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case neutral
    case chatGPT
    case claude
    case grok

    public var artifactID: String {
        switch self {
        case .neutral: return "instructions-provider-neutral"
        case .chatGPT: return "instructions-chatgpt"
        case .claude: return "instructions-claude"
        case .grok: return "instructions-grok"
        }
    }

    public var relativePath: String {
        switch self {
        case .neutral: return "instructions/provider-neutral.txt"
        case .chatGPT: return "instructions/chatgpt.txt"
        case .claude: return "instructions/claude.txt"
        case .grok: return "instructions/grok.txt"
        }
    }
}

public struct RoomAIProviderInstructionFile: Sendable, Equatable {
    public var provider: RoomAIProviderInstructionProvider
    public var artifactID: String
    public var relativePath: String
    public var truthSHA256: String
    public var data: Data

    public init(
        provider: RoomAIProviderInstructionProvider,
        artifactID: String,
        relativePath: String,
        truthSHA256: String,
        data: Data
    ) {
        self.provider = provider
        self.artifactID = artifactID
        self.relativePath = relativePath
        self.truthSHA256 = truthSHA256
        self.data = data
    }
}

public struct RoomAIProviderInstructionSet: Sendable, Equatable {
    public var truthSHA256: String
    public var files: [RoomAIProviderInstructionFile]

    public init(truthSHA256: String, files: [RoomAIProviderInstructionFile]) {
        self.truthSHA256 = truthSHA256
        self.files = files
    }
}

public struct RoomAIArtifactBuildInput: Sendable, Equatable {
    public var slot: RoomAIArtifactSlot
    public var disposition: RoomArtifactDisposition
    public var sourceURL: URL?
    public var relativePath: String?
    public var mediaType: String?
    public var reasonCode: String?

    public init(
        slot: RoomAIArtifactSlot,
        disposition: RoomArtifactDisposition,
        sourceURL: URL? = nil,
        relativePath: String? = nil,
        mediaType: String? = nil,
        reasonCode: String? = nil
    ) {
        self.slot = slot
        self.disposition = disposition
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.reasonCode = reasonCode
    }

    public static func included(
        slot: RoomAIArtifactSlot,
        sourceURL: URL,
        relativePath: String,
        mediaType: String
    ) -> Self {
        Self(
            slot: slot,
            disposition: .included,
            sourceURL: sourceURL,
            relativePath: relativePath,
            mediaType: mediaType
        )
    }

    public static func unavailable(slot: RoomAIArtifactSlot, reasonCode: String) -> Self {
        Self(slot: slot, disposition: .unavailable, reasonCode: reasonCode)
    }

    public static func excluded(slot: RoomAIArtifactSlot, reasonCode: String) -> Self {
        Self(slot: slot, disposition: .excluded, reasonCode: reasonCode)
    }

    public static func skipped(slot: RoomAIArtifactSlot, reasonCode: String) -> Self {
        Self(slot: slot, disposition: .skipped, reasonCode: reasonCode)
    }

    public static func failed(slot: RoomAIArtifactSlot, reasonCode: String) -> Self {
        Self(slot: slot, disposition: .failed, reasonCode: reasonCode)
    }
}

public struct RoomAIIncludedArtifactSource: Sendable, Equatable {
    public var slot: RoomAIArtifactSlot
    public var sourceURL: URL
    public var entryPath: RoomExportEntryPath
    public var mediaType: String
    public var frozenDigest: RoomZIPEntryDigest

    public init(
        slot: RoomAIArtifactSlot,
        sourceURL: URL,
        entryPath: RoomExportEntryPath,
        mediaType: String,
        frozenDigest: RoomZIPEntryDigest
    ) {
        self.slot = slot
        self.sourceURL = sourceURL
        self.entryPath = entryPath
        self.mediaType = mediaType
        self.frozenDigest = frozenDigest
    }
}

public struct RoomAIRoomPackagePreparation: Sendable, Equatable {
    public var packageID: String
    public var profile: RoomAIRoomPackageProfile
    public var sourceRevision: RoomRedesignSourceRevision
    public var artifactPlan: [RoomAIArtifactSlot]
    public var artifactPlanSHA256: String
    public var selectionSHA256: String
    public var artifacts: [RoomAIRoomPackageArtifact]
    public var includedSources: [RoomAIIncludedArtifactSource]

    public init(
        packageID: String,
        profile: RoomAIRoomPackageProfile,
        sourceRevision: RoomRedesignSourceRevision,
        artifactPlan: [RoomAIArtifactSlot],
        artifactPlanSHA256: String,
        selectionSHA256: String,
        artifacts: [RoomAIRoomPackageArtifact],
        includedSources: [RoomAIIncludedArtifactSource]
    ) {
        self.packageID = packageID
        self.profile = profile
        self.sourceRevision = sourceRevision
        self.artifactPlan = artifactPlan
        self.artifactPlanSHA256 = artifactPlanSHA256
        self.selectionSHA256 = selectionSHA256
        self.artifacts = artifacts
        self.includedSources = includedSources
    }

    public func finalize(disclosureReview: RoomDisclosureReview) throws -> RoomAIRoomPackage {
        let package = RoomAIRoomPackage(
            packageID: packageID,
            profile: profile,
            sourceRevision: sourceRevision,
            artifactPlan: artifactPlan,
            artifactPlanSHA256: artifactPlanSHA256,
            selectionSHA256: selectionSHA256,
            disclosureReview: disclosureReview,
            artifacts: artifacts
        )
        try package.validate()
        return package
    }
}

public enum RoomAIRoomPackageBuilder {
    public static func prepare(
        packageID: String,
        plan: RoomAIArtifactPlan,
        inputs: [RoomAIArtifactBuildInput],
        limits: RoomZIPLimits = RoomZIPLimits()
    ) async throws -> RoomAIRoomPackagePreparation {
        guard RoomPathValidation.isSafeStableIdentifier(packageID) else {
            throw RoomAIRoomPackageError.invalidPlan("invalid-package-id")
        }
        try RoomAIArtifactPlan.validateSlots(plan.slots, profile: plan.profile, at: "artifactPlan")
        guard plan.artifactPlanSHA256 == (try RoomRedesignContractDigests.aiArtifactPlanSHA256(
            sourceRevision: plan.sourceRevision,
            profile: plan.profile,
            slots: plan.slots
        )) else {
            throw RoomAIRoomPackageError.invalidPlan("artifact-plan-digest")
        }
        guard inputs.count == plan.slots.count,
              Set(inputs.map(\.slot.artifactID)).count == inputs.count
        else {
            throw RoomAIRoomPackageError.ledgerMismatch
        }
        let inputByID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.slot.artifactID, $0) })
        guard plan.slots.allSatisfy({ inputByID[$0.artifactID]?.slot == $0 }) else {
            throw RoomAIRoomPackageError.ledgerMismatch
        }

        var zipInputs: [RoomZIPInput] = []
        for slot in plan.slots {
            guard let input = inputByID[slot.artifactID] else {
                throw RoomAIRoomPackageError.ledgerMismatch
            }
            switch input.disposition {
            case .included:
                guard let sourceURL = input.sourceURL,
                      let relativePath = input.relativePath,
                      let mediaType = input.mediaType,
                      input.reasonCode == nil,
                      relativePath != "manifest.json"
                else {
                    throw RoomAIRoomPackageError.ledgerMismatch
                }
                zipInputs.append(RoomZIPInput(
                    sourceURL: sourceURL,
                    entryPath: try RoomExportEntryPath(relativePath),
                    mediaType: mediaType
                ))
            case .excluded, .skipped, .unavailable, .failed:
                guard input.sourceURL == nil,
                      input.relativePath == nil,
                      input.mediaType == nil,
                      let reasonCode = input.reasonCode,
                      RoomPathValidation.isSafeStableIdentifier(reasonCode)
                else {
                    throw RoomAIRoomPackageError.ledgerMismatch
                }
            }
        }
        let digests = try await RoomDeterministicZIP.preflight(inputs: zipInputs, limits: limits)
        let digestByPath = Dictionary(uniqueKeysWithValues: digests.map { ($0.entryPath.value, $0) })
        var artifacts: [RoomAIRoomPackageArtifact] = []
        var includedSources: [RoomAIIncludedArtifactSource] = []
        for slot in plan.slots {
            guard let input = inputByID[slot.artifactID] else {
                throw RoomAIRoomPackageError.ledgerMismatch
            }
            let artifact: RoomAIRoomPackageArtifact
            if input.disposition == .included {
                guard let sourceURL = input.sourceURL,
                      let relativePath = input.relativePath,
                      let mediaType = input.mediaType,
                      let digest = digestByPath[relativePath]
                else {
                    throw RoomAIRoomPackageError.ledgerMismatch
                }
                artifact = RoomAIRoomPackageArtifact(
                    artifactID: slot.artifactID,
                    artifactClass: slot.artifactClass,
                    disposition: .included,
                    relativePath: relativePath,
                    sha256: digest.sha256Hex,
                    byteCount: digest.byteCount,
                    mediaType: mediaType
                )
                includedSources.append(RoomAIIncludedArtifactSource(
                    slot: slot,
                    sourceURL: sourceURL,
                    entryPath: digest.entryPath,
                    mediaType: mediaType,
                    frozenDigest: digest
                ))
            } else {
                artifact = RoomAIRoomPackageArtifact(
                    artifactID: slot.artifactID,
                    artifactClass: slot.artifactClass,
                    disposition: input.disposition,
                    reasonCode: input.reasonCode
                )
            }
            try artifact.validate(at: "artifacts.\(slot.artifactID)")
            try RoomAIArtifactPolicy.validateIncludedArtifact(
                artifact,
                at: "artifacts.\(slot.artifactID)"
            )
            artifacts.append(artifact)
        }
        try RoomAIArtifactPolicy.validateProfileLedger(artifacts, profile: plan.profile)
        let selectionSHA256 = try RoomRedesignContractDigests.aiSelectionSHA256(
            artifacts: artifacts
        )
        return RoomAIRoomPackagePreparation(
            packageID: packageID,
            profile: plan.profile,
            sourceRevision: plan.sourceRevision,
            artifactPlan: plan.slots,
            artifactPlanSHA256: plan.artifactPlanSHA256,
            selectionSHA256: selectionSHA256,
            artifacts: artifacts,
            includedSources: includedSources.sorted { $0.entryPath < $1.entryPath }
        )
    }

    public static func validatedQualityCarrierBytes(
        _ carrier: RoomQualityReportCarrierV1,
        boundTo sourceRevision: RoomRedesignSourceRevision
    ) throws -> Data {
        guard carrier.sourceRevision == sourceRevision else {
            throw RoomAIRoomPackageError.qualityCarrierMismatch
        }
        do {
            try carrier.validate()
            let bytes = try RoomRedesignCanonicalJSON.encode(carrier)
            let decoded = try RoomJSONCoding.makeDecoder().decode(
                RoomQualityReportCarrierV1.self,
                from: bytes
            )
            guard decoded == carrier else {
                throw RoomAIRoomPackageError.qualityCarrierMismatch
            }
            return bytes
        } catch let error as RoomAIRoomPackageError {
            throw error
        } catch {
            throw RoomAIRoomPackageError.qualityCarrierMismatch
        }
    }

    public static func makeProviderInstructions(
        context: RoomAIRoomPackageReadyContext,
        plan: RoomAIArtifactPlan,
        selectedReferenceImageIDs: [String],
        qualityCarrier: RoomQualityReportCarrierV1?
    ) throws -> RoomAIProviderInstructionSet {
        try context.validate()
        guard plan.sourceRevision == context.sourceRevision,
              selectedReferenceImageIDs.count <= RoomAIReferenceImageSelector.completeLimit,
              Set(selectedReferenceImageIDs).count == selectedReferenceImageIDs.count,
              selectedReferenceImageIDs.allSatisfy(RoomPathValidation.isSafeStableIdentifier)
        else {
            throw RoomAIRoomPackageError.invalidPlan("instruction-truth-binding")
        }
        let qualitySHA256: String?
        if let qualityCarrier {
            qualitySHA256 = RoomSHA256.hexDigest(of: try validatedQualityCarrierBytes(
                qualityCarrier,
                boundTo: context.sourceRevision
            ))
        } else {
            qualitySHA256 = nil
        }
        let truth = InstructionTruthProjection(
            schemaVersion: "roomscan-ai-instruction-truth-v1",
            sourceRevision: context.sourceRevision,
            orientationSHA256: try RoomRedesignCanonicalJSON.sha256(context.orientation),
            redesignIntentSHA256: try RoomRedesignCanonicalJSON.sha256(context.redesignIntent),
            qualityCarrierSHA256: qualitySHA256,
            artifactPlanSHA256: plan.artifactPlanSHA256,
            selectedReferenceImageIDs: selectedReferenceImageIDs.sorted()
        )
        let truthSHA256 = try RoomRedesignCanonicalJSON.sha256(truth)
        let files = RoomAIProviderInstructionProvider.allCases.map { provider in
            let text = instructionText(
                provider: provider,
                context: context,
                truthSHA256: truthSHA256,
                planSHA256: plan.artifactPlanSHA256,
                qualitySHA256: qualitySHA256
            )
            return RoomAIProviderInstructionFile(
                provider: provider,
                artifactID: provider.artifactID,
                relativePath: provider.relativePath,
                truthSHA256: truthSHA256,
                data: Data(text.utf8)
            )
        }
        return RoomAIProviderInstructionSet(truthSHA256: truthSHA256, files: files)
    }

    public static func canonicalManifestData(_ package: RoomAIRoomPackage) throws -> Data {
        try package.validate()
        let data = try RoomRedesignCanonicalJSON.encode(package)
        guard case let .aiRoomPackage(decoded) = try RoomRedesignContractValidator.validate(data: data),
              decoded == package
        else {
            throw RoomAIRoomPackageError.invalidManifest("canonical-round-trip")
        }
        return data
    }

    private struct InstructionTruthProjection: Encodable {
        var schemaVersion: String
        var sourceRevision: RoomRedesignSourceRevision
        var orientationSHA256: String
        var redesignIntentSHA256: String
        var qualityCarrierSHA256: String?
        var artifactPlanSHA256: String
        var selectedReferenceImageIDs: [String]
    }

    private static func instructionText(
        provider: RoomAIProviderInstructionProvider,
        context: RoomAIRoomPackageReadyContext,
        truthSHA256: String,
        planSHA256: String,
        qualitySHA256: String?
    ) -> String {
        let heading: String
        let workflow: String
        switch provider {
        case .neutral:
            heading = "Provider-neutral room redesign brief"
            workflow = "Use the manifest and canonical views as the ordered source of truth."
        case .chatGPT:
            heading = "ChatGPT room redesign brief"
            workflow = "Review the manifest first, then reason across the canonical views before proposing concepts."
        case .claude:
            heading = "Claude room redesign brief"
            workflow = "Reconcile the structured truth and visual references explicitly before drafting concepts."
        case .grok:
            heading = "Grok room redesign brief"
            workflow = "Inspect the bound room facts and canonical views before generating alternatives."
        }
        return """
        \(heading)
        Truth digest: \(truthSHA256)
        Artifact plan digest: \(planSHA256)
        Source project: \(context.sourceRevision.projectID)
        Source revision: \(context.sourceRevision.revisionID)
        Coordinate-space epoch: \(context.sourceRevision.coordinateSpaceEpochID)
        Semantic digest: \(context.sourceRevision.semanticSHA256)
        Revision-manifest digest: \(context.sourceRevision.revisionManifestSHA256)
        Orientation digest: \((try? RoomRedesignCanonicalJSON.sha256(context.orientation)) ?? "invalid")
        Intent digest: \((try? RoomRedesignCanonicalJSON.sha256(context.redesignIntent)) ?? "invalid")
        Quality carrier digest: \(qualitySHA256 ?? "unavailable")
        Scope: \(context.redesignIntent.scope.rawValue)
        Verbatim request: \(context.redesignIntent.request)
        \(workflow)
        Preserve captured geometry, measurements, openings, and every preserve permission as factual constraints.
        External models may not follow every instruction; verify output against the manifest.
        Renovate and Reimagine output is conceptual and is not construction, survey, or code-compliance guidance.
        """ + "\n"
    }
}
