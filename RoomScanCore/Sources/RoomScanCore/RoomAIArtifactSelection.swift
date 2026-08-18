import Foundation

public enum RoomAIRoomPackageError: Error, Sendable, Equatable {
    case invalidPlan(String)
    case sourceRevisionMismatch
    case orientationConfirmationRequired
    case redesignIntentRequired
    case invalidReferenceCandidate(String)
    case ledgerMismatch
    case qualityCarrierMismatch
    case failedArtifact(String)
    case invalidManifest(String)
    case archiveClosureMismatch(String)
}

/// One immutable requested artifact position. Class repetition is deliberate:
/// stable IDs distinguish six canonical views, reference images, textures,
/// provider instructions, and Complete-only evidence records.
public struct RoomAIArtifactSlot: Codable, Sendable, Equatable, Hashable {
    public var artifactID: String
    public var artifactClass: RoomRedesignArtifactClass

    public init(artifactID: String, artifactClass: RoomRedesignArtifactClass) {
        self.artifactID = artifactID
        self.artifactClass = artifactClass
    }

    public static func canonicalized(_ slots: [Self]) -> [Self] {
        slots.sorted {
            if $0.artifactClass.aiPackageCanonicalRank != $1.artifactClass.aiPackageCanonicalRank {
                return $0.artifactClass.aiPackageCanonicalRank < $1.artifactClass.aiPackageCanonicalRank
            }
            return $0.artifactID < $1.artifactID
        }
    }
}

public struct RoomAIArtifactPlan: Sendable, Equatable {
    public let sourceRevision: RoomRedesignSourceRevision
    public let profile: RoomAIRoomPackageProfile
    public let slots: [RoomAIArtifactSlot]
    public let artifactPlanSHA256: String

    public static func make(
        sourceRevision: RoomRedesignSourceRevision,
        profile: RoomAIRoomPackageProfile,
        slots: [RoomAIArtifactSlot]
    ) throws -> Self {
        try sourceRevision.validate()
        let canonical = RoomAIArtifactSlot.canonicalized(slots)
        try validateSlots(canonical, profile: profile, at: "artifactPlan")
        return Self(
            sourceRevision: sourceRevision,
            profile: profile,
            slots: canonical,
            artifactPlanSHA256: try RoomRedesignContractDigests.aiArtifactPlanSHA256(
                sourceRevision: sourceRevision,
                profile: profile,
                slots: canonical
            )
        )
    }

    public func isExplicitSuperset(of aiReadyPlan: Self) -> Bool {
        guard profile == .complete,
              aiReadyPlan.profile == .aiReady,
              sourceRevision == aiReadyPlan.sourceRevision
        else { return false }
        let completeSlots = Set(slots)
        return aiReadyPlan.slots.allSatisfy(completeSlots.contains)
    }

    public static func validateSlots(
        _ slots: [RoomAIArtifactSlot],
        profile: RoomAIRoomPackageProfile,
        at path: String
    ) throws {
        guard !slots.isEmpty, slots.count <= 1_000 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "AI artifact plans must be nonempty and bounded."
            )
        }
        for (index, slot) in slots.enumerated() {
            guard RoomPathValidation.isSafeStableIdentifier(slot.artifactID) else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "\(path)[\(index)].artifactID",
                    reason: "Artifact IDs must be stable portable identifiers."
                )
            }
        }
        guard Set(slots.map(\.artifactID)).count == slots.count else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).artifactID",
                reason: "Artifact slot IDs must be unique."
            )
        }
        guard slots == RoomAIArtifactSlot.canonicalized(slots) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Artifact slots must use class-rank then ASCII-ID canonical order."
            )
        }

        let alwaysAllowed: Set<RoomRedesignArtifactClass> = [
            .normalizedSemantics, .revisionLineage, .orientation, .floorPlan,
            .canonicalView, .selectedReferenceImage, .materials, .qualityReport,
            .roomBrief, .redesignIntent, .providerInstructions, .mesh, .texture,
        ]
        let completeOnly: Set<RoomRedesignArtifactClass> = [
            .rawRGB, .rawDepth, .rawConfidence, .diagnostics,
        ]
        let allowed = profile == .complete ? alwaysAllowed.union(completeOnly) : alwaysAllowed
        guard slots.allSatisfy({ allowed.contains($0.artifactClass) }) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "The profile contains a raw, world-map, sync-only, or otherwise unallowlisted AI artifact slot."
            )
        }

        func count(_ artifactClass: RoomRedesignArtifactClass) -> Int {
            slots.lazy.filter { $0.artifactClass == artifactClass }.count
        }
        for singleton in [
            RoomRedesignArtifactClass.normalizedSemantics, .revisionLineage,
            .orientation, .floorPlan, .materials, .qualityReport, .roomBrief,
            .redesignIntent,
        ] where count(singleton) != 1 {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "AI artifact plans require exactly one \(singleton.rawValue) slot."
            )
        }
        guard count(.canonicalView) == 6 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "AI artifact plans require exactly six canonical-view slots."
            )
        }
        let instructionIDs = Set(slots.compactMap {
            $0.artifactClass == .providerInstructions ? $0.artifactID : nil
        })
        guard instructionIDs == Set(RoomAIProviderInstructionProvider.allCases.map(\.artifactID)) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "AI artifact plans require the exact neutral, ChatGPT, Claude, and Grok instruction slots."
            )
        }
        guard (1...64).contains(count(.selectedReferenceImage)),
              (1...32).contains(count(.mesh)),
              (1...64).contains(count(.texture))
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Optional AI artifact classes require bounded explicit available or unavailable slots."
            )
        }
        if profile == .complete {
            for artifactClass in completeOnly where !(1...64).contains(count(artifactClass)) {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: path,
                    reason: "Complete plans require bounded explicit raw/diagnostic slots, including unavailable records."
                )
            }
        }
    }
}

public struct RoomAIRoomPackageReadyContext: Sendable, Equatable {
    public let sourceRevision: RoomRedesignSourceRevision
    public let orientation: RoomOrientationContractV2
    public let redesignIntent: RoomRedesignIntentV2

    func validate() throws {
        try sourceRevision.validate()
        try orientation.validate(boundTo: sourceRevision)
        try redesignIntent.validate()
        guard orientation.source == .confirmed || orientation.source == .manual else {
            throw RoomAIRoomPackageError.orientationConfirmationRequired
        }
    }
}

public enum RoomAIRoomPackageReadiness {
    public static func requireEligible(
        sourceRevision: RoomRedesignSourceRevision,
        companion: RoomLocalRedesignExtensionV2
    ) throws -> RoomAIRoomPackageReadyContext {
        do {
            try sourceRevision.validate()
            try companion.validate()
        } catch {
            throw RoomAIRoomPackageError.sourceRevisionMismatch
        }
        guard companion.sourceRevision == sourceRevision else {
            throw RoomAIRoomPackageError.sourceRevisionMismatch
        }
        guard companion.orientation.source == .confirmed || companion.orientation.source == .manual else {
            throw RoomAIRoomPackageError.orientationConfirmationRequired
        }
        guard let intent = companion.redesignIntent else {
            throw RoomAIRoomPackageError.redesignIntentRequired
        }
        let context = RoomAIRoomPackageReadyContext(
            sourceRevision: sourceRevision,
            orientation: companion.orientation,
            redesignIntent: intent
        )
        try context.validate()
        return context
    }
}

public struct RoomAIReferenceImageCandidate: Sendable, Equatable {
    public var evidenceID: String
    /// Nil represents a legacy capture bundle that cannot safely be rebound.
    public var sourceRevision: RoomRedesignSourceRevision?
    public var capturedAt: Date
    public var sharpness: Double

    public init(
        evidenceID: String,
        sourceRevision: RoomRedesignSourceRevision?,
        capturedAt: Date,
        sharpness: Double
    ) {
        self.evidenceID = evidenceID
        self.sourceRevision = sourceRevision
        self.capturedAt = capturedAt
        self.sharpness = sharpness
    }
}

public struct RoomAIReferenceImageSelection: Sendable, Equatable {
    public var selected: [RoomAIReferenceImageCandidate]
    public var skipped: [RoomAIReferenceImageCandidate]
    public var unavailable: [RoomAIReferenceImageCandidate]

    public init(
        selected: [RoomAIReferenceImageCandidate],
        skipped: [RoomAIReferenceImageCandidate],
        unavailable: [RoomAIReferenceImageCandidate]
    ) {
        self.selected = selected
        self.skipped = skipped
        self.unavailable = unavailable
    }
}

public enum RoomAIReferenceImageSelector {
    public static let aiReadyLimit = 4
    public static let completeLimit = 8
    public static let maximumCandidateCount = 64

    public static func select(
        candidates: [RoomAIReferenceImageCandidate],
        sourceRevision: RoomRedesignSourceRevision,
        profile: RoomAIRoomPackageProfile
    ) throws -> RoomAIReferenceImageSelection {
        try sourceRevision.validate()
        guard candidates.count <= maximumCandidateCount,
              Set(candidates.map(\.evidenceID)).count == candidates.count
        else {
            throw RoomAIRoomPackageError.invalidReferenceCandidate("candidate-count-or-duplicate-id")
        }
        var bound: [RoomAIReferenceImageCandidate] = []
        var unavailable: [RoomAIReferenceImageCandidate] = []
        for candidate in candidates {
            guard RoomPathValidation.isSafeStableIdentifier(candidate.evidenceID),
                  candidate.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                  candidate.sharpness.isFinite,
                  candidate.sharpness >= 0
            else {
                throw RoomAIRoomPackageError.invalidReferenceCandidate(candidate.evidenceID)
            }
            guard let binding = candidate.sourceRevision else {
                unavailable.append(candidate)
                continue
            }
            guard binding == sourceRevision else {
                throw RoomAIRoomPackageError.sourceRevisionMismatch
            }
            bound.append(candidate)
        }
        bound.sort {
            if $0.sharpness != $1.sharpness { return $0.sharpness > $1.sharpness }
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            return $0.evidenceID < $1.evidenceID
        }
        unavailable.sort { $0.evidenceID < $1.evidenceID }
        let limit = profile == .aiReady ? aiReadyLimit : completeLimit
        return RoomAIReferenceImageSelection(
            selected: Array(bound.prefix(limit)),
            skipped: Array(bound.dropFirst(limit)),
            unavailable: unavailable
        )
    }
}

public struct RoomAIArtifactInventory: Sendable, Equatable {
    public var referenceImageIDs: [String]
    public var meshIDs: [String]
    public var textureIDs: [String]
    public var rawRGBIDs: [String]
    public var rawDepthIDs: [String]
    public var rawConfidenceIDs: [String]
    public var diagnosticIDs: [String]

    public init(
        referenceImageIDs: [String] = [],
        meshIDs: [String] = [],
        textureIDs: [String] = [],
        rawRGBIDs: [String] = [],
        rawDepthIDs: [String] = [],
        rawConfidenceIDs: [String] = [],
        diagnosticIDs: [String] = []
    ) {
        self.referenceImageIDs = referenceImageIDs
        self.meshIDs = meshIDs
        self.textureIDs = textureIDs
        self.rawRGBIDs = rawRGBIDs
        self.rawDepthIDs = rawDepthIDs
        self.rawConfidenceIDs = rawConfidenceIDs
        self.diagnosticIDs = diagnosticIDs
    }
}

public enum RoomAIArtifactPlanner {
    public static func makePlan(
        profile: RoomAIRoomPackageProfile,
        context: RoomAIRoomPackageReadyContext,
        inventory: RoomAIArtifactInventory
    ) throws -> RoomAIArtifactPlan {
        try context.validate()
        let rawGroups = [
            inventory.rawRGBIDs, inventory.rawDepthIDs,
            inventory.rawConfidenceIDs, inventory.diagnosticIDs,
        ]
        if profile == .aiReady, rawGroups.contains(where: { !$0.isEmpty }) {
            throw RoomAIRoomPackageError.invalidPlan("ai-ready-raw-slot")
        }
        for group in [
            inventory.referenceImageIDs, inventory.meshIDs, inventory.textureIDs,
        ] + rawGroups {
            guard group.count <= 64,
                  Set(group).count == group.count,
                  group.allSatisfy(RoomPathValidation.isSafeStableIdentifier)
            else {
                throw RoomAIRoomPackageError.invalidPlan("invalid-or-duplicate-inventory-id")
            }
        }

        var slots = [
            RoomAIArtifactSlot(artifactID: "semantic-model", artifactClass: .normalizedSemantics),
            RoomAIArtifactSlot(artifactID: "revision-lineage", artifactClass: .revisionLineage),
            RoomAIArtifactSlot(artifactID: "orientation", artifactClass: .orientation),
            RoomAIArtifactSlot(artifactID: "floor-plan", artifactClass: .floorPlan),
        ]
        slots.append(contentsOf: context.orientation.canonicalCameras.map {
            RoomAIArtifactSlot(
                artifactID: "canonical-view-\($0.cameraID)",
                artifactClass: .canonicalView
            )
        })
        slots.append(contentsOf: slotsForIDs(
            inventory.referenceImageIDs,
            prefix: "reference-image-",
            unavailableID: "reference-image-unavailable",
            artifactClass: .selectedReferenceImage
        ))
        slots.append(RoomAIArtifactSlot(artifactID: "materials", artifactClass: .materials))
        slots.append(RoomAIArtifactSlot(artifactID: "quality-report-carrier", artifactClass: .qualityReport))
        slots.append(RoomAIArtifactSlot(artifactID: "room-brief", artifactClass: .roomBrief))
        slots.append(RoomAIArtifactSlot(artifactID: "redesign-intent", artifactClass: .redesignIntent))
        slots.append(contentsOf: RoomAIProviderInstructionProvider.allCases.map {
            RoomAIArtifactSlot(artifactID: $0.artifactID, artifactClass: .providerInstructions)
        })
        slots.append(contentsOf: slotsForIDs(
            inventory.meshIDs,
            prefix: "mesh-",
            unavailableID: "mesh-unavailable",
            artifactClass: .mesh
        ))
        slots.append(contentsOf: slotsForIDs(
            inventory.textureIDs,
            prefix: "texture-",
            unavailableID: "texture-unavailable",
            artifactClass: .texture
        ))
        if profile == .complete {
            slots.append(contentsOf: slotsForIDs(
                inventory.rawRGBIDs,
                prefix: "raw-rgb-",
                unavailableID: "raw-rgb-unavailable",
                artifactClass: .rawRGB
            ))
            slots.append(contentsOf: slotsForIDs(
                inventory.rawDepthIDs,
                prefix: "raw-depth-",
                unavailableID: "raw-depth-unavailable",
                artifactClass: .rawDepth
            ))
            slots.append(contentsOf: slotsForIDs(
                inventory.rawConfidenceIDs,
                prefix: "raw-confidence-",
                unavailableID: "raw-confidence-unavailable",
                artifactClass: .rawConfidence
            ))
            slots.append(contentsOf: slotsForIDs(
                inventory.diagnosticIDs,
                prefix: "diagnostics-",
                unavailableID: "diagnostics-unavailable",
                artifactClass: .diagnostics
            ))
        }
        return try RoomAIArtifactPlan.make(
            sourceRevision: context.sourceRevision,
            profile: profile,
            slots: slots
        )
    }

    private static func slotsForIDs(
        _ ids: [String],
        prefix: String,
        unavailableID: String,
        artifactClass: RoomRedesignArtifactClass
    ) -> [RoomAIArtifactSlot] {
        let values = ids.isEmpty ? [unavailableID] : ids.map { prefix + $0 }
        return values.map { RoomAIArtifactSlot(artifactID: $0, artifactClass: artifactClass) }
    }
}

enum RoomAIArtifactPolicy {
    static func validateIncludedArtifact(
        _ artifact: RoomAIRoomPackageArtifact,
        at path: String
    ) throws {
        guard artifact.disposition == .included else { return }
        guard let relativePath = artifact.relativePath,
              let mediaType = artifact.mediaType,
              allowedPath(relativePath, mediaType: mediaType, for: artifact.artifactClass)
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Included AI artifacts must use their allowlisted archive namespace and media type."
            )
        }
    }

    static func validateProfileLedger(
        _ artifacts: [RoomAIRoomPackageArtifact],
        profile: RoomAIRoomPackageProfile
    ) throws {
        func included(_ artifactClass: RoomRedesignArtifactClass) -> Int {
            artifacts.lazy.filter {
                $0.artifactClass == artifactClass && $0.disposition == .included
            }.count
        }
        for required in [
            RoomRedesignArtifactClass.normalizedSemantics, .revisionLineage,
            .orientation, .floorPlan, .roomBrief, .redesignIntent,
        ] where included(required) != 1 {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "artifacts",
                reason: "A distributable AI package must include its required \(required.rawValue) artifact."
            )
        }
        guard included(.canonicalView) == 6,
              included(.providerInstructions) == 4
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "artifacts",
                reason: "A distributable AI package must include six canonical views and four provider instructions."
            )
        }
        let referenceLimit = profile == .aiReady
            ? RoomAIReferenceImageSelector.aiReadyLimit
            : RoomAIReferenceImageSelector.completeLimit
        guard included(.selectedReferenceImage) <= referenceLimit else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "artifacts",
                reason: "Selected sharp reference images exceed the fixed profile limit."
            )
        }
    }

    private static func allowedPath(
        _ path: String,
        mediaType: String,
        for artifactClass: RoomRedesignArtifactClass
    ) -> Bool {
        switch artifactClass {
        case .normalizedSemantics:
            return path == "truth/semantic-model.json" && mediaType == "application/json"
        case .revisionLineage:
            return path == "truth/revision-lineage.json" && mediaType == "application/json"
        case .orientation:
            return path == "truth/orientation.json" && mediaType == "application/json"
        case .floorPlan:
            return path == "derivatives/floor-plan.png" && mediaType == "image/png"
        case .canonicalView:
            return path.hasPrefix("derivatives/canonical-views/")
                && path.hasSuffix(".png") && mediaType == "image/png"
        case .selectedReferenceImage:
            return path.hasPrefix("references/")
                && path.hasSuffix(".jpg") && mediaType == "image/jpeg"
        case .materials:
            return path == "appearance/materials.json" && mediaType == "application/json"
        case .qualityReport:
            return path == "quality/quality-report-carrier.json" && mediaType == "application/json"
        case .roomBrief:
            return path == "brief/room-brief.txt" && mediaType == "text/plain"
        case .redesignIntent:
            return path == "intent/redesign-intent.json" && mediaType == "application/json"
        case .providerInstructions:
            return path.hasPrefix("instructions/")
                && path.hasSuffix(".txt") && mediaType == "text/plain"
        case .mesh:
            return path.hasPrefix("geometry/") && [
                "model/vnd.usdz+zip", "model/gltf-binary", "model/obj",
                "text/plain", "application/octet-stream",
            ].contains(mediaType)
        case .texture:
            return path.hasPrefix("appearance/textures/")
                && path.hasSuffix(".png") && mediaType == "image/png"
        case .rawRGB:
            return path.hasPrefix("raw/") && ["image/jpeg", "image/png", "image/heic"].contains(mediaType)
        case .rawDepth, .rawConfidence:
            return path.hasPrefix("raw/") && mediaType == "application/octet-stream"
        case .diagnostics:
            return path.hasPrefix("diagnostics/")
                && path.hasSuffix(".json") && mediaType == "application/json"
        case .conceptAttachment, .comments, .worldMap:
            return false
        }
    }
}
