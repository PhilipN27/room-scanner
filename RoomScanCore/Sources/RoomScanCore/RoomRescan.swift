import Foundation

/// A rescan candidate is valid only if one of these registrations is proven: 1. continuous capture in the original app-owned ARSession, or 2. successful relocalization against a recorded ARWorldMap.
///
/// Phase 3 V1-A deliberately implements neither live registration path. The
/// only accepted form below is a typed, deterministic bundled-fixture proof so
/// preview and immutable lineage can be exercised without claiming live AR
/// continuity or world-map relocalization.
public struct RoomDeterministicRescanRegistrationProof: Codable, Sendable, Equatable {
    public static let fixtureV1ID = "rescan-fixture-v1"
    public static let fixtureV1FrameID = "mock-room-v1-frame"
    public static let fixtureV1ProofToken = "deterministic-rescan-registration-v1"

    public var fixtureID: String
    public var projectID: String
    public var baseRevisionID: String
    public var coordinateFrameID: String
    public var proofToken: String

    public init(
        fixtureID: String,
        projectID: String,
        baseRevisionID: String,
        coordinateFrameID: String,
        proofToken: String
    ) {
        self.fixtureID = fixtureID
        self.projectID = projectID
        self.baseRevisionID = baseRevisionID
        self.coordinateFrameID = coordinateFrameID
        self.proofToken = proofToken
    }
}

public enum RoomRescanSemanticLayer: String, Codable, Sendable, Equatable {
    case structural
    case object
}

/// An explicit correspondence. It declares each endpoint's observed layer and
/// category so the fixture loader can fail closed on a changed classification
/// rather than treating it as a safe replacement.
public struct RoomRescanElementMatch: Codable, Sendable, Equatable {
    public var baseElementID: String
    public var candidateElementID: String
    public var baseLayer: RoomRescanSemanticLayer
    public var candidateLayer: RoomRescanSemanticLayer
    public var baseKind: String
    public var candidateKind: String

    public init(
        baseElementID: String,
        candidateElementID: String,
        baseLayer: RoomRescanSemanticLayer,
        candidateLayer: RoomRescanSemanticLayer,
        baseKind: String,
        candidateKind: String
    ) {
        self.baseElementID = baseElementID
        self.candidateElementID = candidateElementID
        self.baseLayer = baseLayer
        self.candidateLayer = candidateLayer
        self.baseKind = baseKind
        self.candidateKind = candidateKind
    }
}

public enum RoomRescanChangeKind: String, Codable, Sendable, Equatable {
    case pose
    case dimensions
    case category
    case label
    case semanticClassification
}

/// A display-only change record. In particular, classification confidence is
/// descriptive framework output; this type intentionally makes no geometric
/// accuracy claim.
public struct RoomRescanChange: Codable, Sendable, Equatable, Identifiable {
    public var elementID: String
    public var kind: RoomRescanChangeKind
    public var oldValue: String
    public var newValue: String

    public var id: String {
        "\(elementID)-\(kind.rawValue)"
    }

    public init(
        elementID: String,
        kind: RoomRescanChangeKind,
        oldValue: String,
        newValue: String
    ) {
        self.elementID = elementID
        self.kind = kind
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

public struct RoomRescanPreview: Codable, Sendable, Equatable {
    public static let unrevalidatedMeasurementsNotice = "Measurements are unchanged and unrevalidated by this rescan proposal."

    public var changes: [RoomRescanChange]
    public var measurementsRemainUnrevalidated: Bool
    public var measurementsNotice: String

    public init(
        changes: [RoomRescanChange],
        measurementsRemainUnrevalidated: Bool = true,
        measurementsNotice: String = RoomRescanPreview.unrevalidatedMeasurementsNotice
    ) {
        self.changes = changes
        self.measurementsRemainUnrevalidated = measurementsRemainUnrevalidated
        self.measurementsNotice = measurementsNotice
    }
}

/// A transient, reviewable fixture proposal. It is never written as durable
/// package truth. Acceptance recomputes it under the store's project lock.
public struct RoomFixtureRescanProposal: Codable, Sendable, Equatable {
    public var projectID: String
    public var baseRevisionID: String
    public var expectedHeadRevisionID: String
    public var registrationProof: RoomDeterministicRescanRegistrationProof
    public var candidateSnapshot: RoomSemanticSnapshot
    public var matches: [RoomRescanElementMatch]
    public var resultPayload: RoomRevisionPayload
    public var preview: RoomRescanPreview
    public var digest: String

    public init(
        projectID: String,
        baseRevisionID: String,
        expectedHeadRevisionID: String,
        registrationProof: RoomDeterministicRescanRegistrationProof,
        candidateSnapshot: RoomSemanticSnapshot,
        matches: [RoomRescanElementMatch],
        resultPayload: RoomRevisionPayload,
        preview: RoomRescanPreview,
        digest: String
    ) {
        self.projectID = projectID
        self.baseRevisionID = baseRevisionID
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.registrationProof = registrationProof
        self.candidateSnapshot = candidateSnapshot
        self.matches = matches
        self.resultPayload = resultPayload
        self.preview = preview
        self.digest = digest
    }
}

public enum RoomRescanError: Error, Sendable, Equatable {
    case unprovenRegistration
    case wrongFixture
    case wrongCoordinateFrame
    case incompleteBijection
    case duplicateMatch
    case layerMismatch
    case kindMismatch
    case invalidCandidateGeometry
    case tamperedProposal

    public var message: String {
        switch self {
        case .unprovenRegistration:
            return "The deterministic registration proof is not valid for this base revision."
        case .wrongFixture:
            return "The deterministic rescan fixture identifier is not recognized."
        case .wrongCoordinateFrame:
            return "The deterministic rescan candidate is not in the expected fixture frame."
        case .incompleteBijection:
            return "Fixture rescans do not support candidate additions or deletions."
        case .duplicateMatch:
            return "Each base and candidate element must have exactly one explicit match."
        case .layerMismatch:
            return "A fixture rescan match cannot move an element between structural and object layers."
        case .kindMismatch:
            return "A fixture rescan match does not describe its observed element category."
        case .invalidCandidateGeometry:
            return "The fixture rescan candidate contains invalid semantic geometry or provenance."
        case .tamperedProposal:
            return "The rescan proposal digest does not match its deterministic inputs."
        }
    }
}

/// Foundation-only semantic replacement for the V1-A deterministic fixture.
/// It is intentionally not a same-room merge or vertex-fusion API.
public enum RoomRescanEngine {
    // V1-A candidate coordinates must be usable affine transforms. The
    // tolerance accepts ordinary serialized floating-point noise while the
    // determinant floor rejects a collapsed/singular semantic pose. This is
    // deliberately narrower than legacy RoomTransform4x4 decoding.
    private static let candidateAffineTolerance = 1e-9
    private static let candidateDeterminantTolerance = 1e-10

    public static func makeFixtureProposal(
        basePayload: RoomRevisionPayload,
        expectedHeadRevisionID: String,
        registrationProof: RoomDeterministicRescanRegistrationProof,
        candidateSnapshot: RoomSemanticSnapshot,
        matches: [RoomRescanElementMatch]
    ) throws -> RoomFixtureRescanProposal {
        let projectID = basePayload.semanticSnapshot.projectID
        let baseRevisionID = basePayload.semanticSnapshot.revisionID
        try validateRegistration(
            registrationProof,
            projectID: projectID,
            baseRevisionID: baseRevisionID,
            expectedHeadRevisionID: expectedHeadRevisionID
        )
        let normalizedBaseSnapshot = normalized(basePayload.semanticSnapshot)
        var normalizedBasePayload = basePayload
        normalizedBasePayload.semanticSnapshot = normalizedBaseSnapshot
        try validateSnapshot(normalizedBaseSnapshot, isCandidate: false)
        let normalizedCandidateSnapshot = normalized(candidateSnapshot)
        try validateSnapshot(normalizedCandidateSnapshot, isCandidate: true)
        guard normalizedCandidateSnapshot.projectID == projectID else {
            throw RoomRescanError.unprovenRegistration
        }

        let normalizedMatches = matches.sorted(by: matchOrder)
        let baseElements = try layeredElements(in: normalizedBaseSnapshot)
        let candidateElements = try layeredElements(in: normalizedCandidateSnapshot)
        try validateExactBijection(
            matches: normalizedMatches,
            baseElements: baseElements,
            candidateElements: candidateElements
        )

        let candidateByID = Dictionary(
            uniqueKeysWithValues: candidateElements.map { ($0.element.id, $0) }
        )
        let matchByBaseID = Dictionary(
            uniqueKeysWithValues: normalizedMatches.map { ($0.baseElementID, $0) }
        )

        let resultingStructural = try resultElements(
            normalizedBaseSnapshot.structuralElements,
            candidateByID: candidateByID,
            matchByBaseID: matchByBaseID
        )
        let resultingObjects = try resultElements(
            normalizedBaseSnapshot.objectElements,
            candidateByID: candidateByID,
            matchByBaseID: matchByBaseID
        )
        let resultSnapshot = RoomSemanticSnapshot(
            projectID: projectID,
            revisionID: baseRevisionID,
            units: normalizedCandidateSnapshot.units,
            accuracyDisclaimer: normalizedCandidateSnapshot.accuracyDisclaimer,
            structuralElements: resultingStructural,
            objectElements: resultingObjects
        )
        let resultPayload = RoomRevisionPayload(
            semanticSnapshot: resultSnapshot,
            annotations: normalizedBasePayload.annotations,
            measurements: normalizedBasePayload.measurements,
            photos: normalizedBasePayload.photos
        )
        let preview = makePreview(
            baseElements: baseElements,
            resultElements: try layeredElements(in: resultSnapshot)
        )
        let digest = try digest(
            projectID: projectID,
            baseRevisionID: baseRevisionID,
            expectedHeadRevisionID: expectedHeadRevisionID,
            registrationProof: registrationProof,
            candidateSnapshot: normalizedCandidateSnapshot,
            matches: normalizedMatches,
            resultPayload: resultPayload,
            preview: preview
        )
        return RoomFixtureRescanProposal(
            projectID: projectID,
            baseRevisionID: baseRevisionID,
            expectedHeadRevisionID: expectedHeadRevisionID,
            registrationProof: registrationProof,
            candidateSnapshot: normalizedCandidateSnapshot,
            matches: normalizedMatches,
            resultPayload: resultPayload,
            preview: preview,
            digest: digest
        )
    }

    /// Rebuild rather than trust a proposal supplied by UI or fixture code.
    public static func verifyFixtureProposal(
        _ proposal: RoomFixtureRescanProposal,
        against basePayload: RoomRevisionPayload
    ) throws -> RoomFixtureRescanProposal {
        let recomputed = try makeFixtureProposal(
            basePayload: basePayload,
            expectedHeadRevisionID: proposal.expectedHeadRevisionID,
            registrationProof: proposal.registrationProof,
            candidateSnapshot: proposal.candidateSnapshot,
            matches: proposal.matches
        )
        guard proposal == recomputed else {
            throw RoomRescanError.tamperedProposal
        }
        return recomputed
    }

    /// V1-A writes a truthful deterministic-fixture evidence plan: every
    /// Apple artifact is explicitly omitted and no evidence directory exists.
    public static func deterministicFixtureEvidencePlan() -> RoomRevisionEvidencePlan {
        RoomRevisionEvidencePlan(
            source: .deterministicFixture,
            artifacts: RoomEvidenceArtifactKind.allCases.map { kind in
                RoomEvidenceArtifact(
                    kind: kind,
                    status: .unavailable,
                    relativePath: nil,
                    byteCount: nil,
                    mediaType: nil,
                    omissionReason: "No Apple capture artifact exists for this deterministic fixture rescan.",
                    sha256Hex: nil
                )
            },
            captureAttemptID: nil,
            coordinateSpaceEpochID: nil
        )
    }

    private struct DigestMaterial: Codable {
        let projectID: String
        let baseRevisionID: String
        let expectedHeadRevisionID: String
        let registrationProof: RoomDeterministicRescanRegistrationProof
        let candidateSnapshot: RoomSemanticSnapshot
        let matches: [RoomRescanElementMatch]
        let resultPayload: RoomRevisionPayload
        let preview: RoomRescanPreview
    }

    private struct LayeredElement {
        let element: RoomSemanticElement
        let layer: RoomRescanSemanticLayer
    }

    private static func digest(
        projectID: String,
        baseRevisionID: String,
        expectedHeadRevisionID: String,
        registrationProof: RoomDeterministicRescanRegistrationProof,
        candidateSnapshot: RoomSemanticSnapshot,
        matches: [RoomRescanElementMatch],
        resultPayload: RoomRevisionPayload,
        preview: RoomRescanPreview
    ) throws -> String {
        let material = DigestMaterial(
            projectID: projectID,
            baseRevisionID: baseRevisionID,
            expectedHeadRevisionID: expectedHeadRevisionID,
            registrationProof: registrationProof,
            candidateSnapshot: candidateSnapshot,
            matches: matches,
            resultPayload: resultPayload,
            preview: preview
        )
        let data: Data
        do {
            data = try RoomJSONCoding.makeEncoder().encode(material)
        } catch {
            throw RoomRescanError.invalidCandidateGeometry
        }
        return RoomSHA256.hexDigest(of: data)
    }

    private static func validateRegistration(
        _ proof: RoomDeterministicRescanRegistrationProof,
        projectID: String,
        baseRevisionID: String,
        expectedHeadRevisionID: String
    ) throws {
        guard proof.fixtureID == RoomDeterministicRescanRegistrationProof.fixtureV1ID else {
            throw RoomRescanError.wrongFixture
        }
        guard proof.coordinateFrameID == RoomDeterministicRescanRegistrationProof.fixtureV1FrameID else {
            throw RoomRescanError.wrongCoordinateFrame
        }
        guard
            proof.proofToken == RoomDeterministicRescanRegistrationProof.fixtureV1ProofToken,
            proof.projectID == projectID,
            proof.baseRevisionID == baseRevisionID,
            expectedHeadRevisionID == baseRevisionID,
            isSafeIdentifier(projectID),
            isSafeIdentifier(baseRevisionID)
        else {
            throw RoomRescanError.unprovenRegistration
        }
    }

    private static func validateSnapshot(
        _ snapshot: RoomSemanticSnapshot,
        isCandidate: Bool
    ) throws {
        guard
            isSafeIdentifier(snapshot.projectID),
            isSafeIdentifier(snapshot.revisionID),
            !snapshot.units.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !snapshot.accuracyDisclaimer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RoomRescanError.invalidCandidateGeometry
        }
        _ = try layeredElements(in: snapshot, isCandidate: isCandidate)
    }

    private static func layeredElements(
        in snapshot: RoomSemanticSnapshot,
        isCandidate: Bool = true
    ) throws -> [LayeredElement] {
        var seenIDs = Set<String>()
        var candidateSourceIdentifiers = Set<String>()
        var result: [LayeredElement] = []
        for element in snapshot.structuralElements {
            guard seenIDs.insert(element.id).inserted else {
                throw isCandidate
                    ? RoomRescanError.invalidCandidateGeometry
                    : RoomRescanError.incompleteBijection
            }
            try validate(element: element, layer: .structural, isCandidate: isCandidate)
            if isCandidate,
               let sourceIdentifier = element.provenance?.sourceIdentifier,
               !candidateSourceIdentifiers.insert(sourceIdentifier).inserted {
                throw RoomRescanError.invalidCandidateGeometry
            }
            result.append(LayeredElement(element: element, layer: .structural))
        }
        for element in snapshot.objectElements {
            guard seenIDs.insert(element.id).inserted else {
                throw isCandidate
                    ? RoomRescanError.invalidCandidateGeometry
                    : RoomRescanError.incompleteBijection
            }
            try validate(element: element, layer: .object, isCandidate: isCandidate)
            if isCandidate,
               let sourceIdentifier = element.provenance?.sourceIdentifier,
               !candidateSourceIdentifiers.insert(sourceIdentifier).inserted {
                throw RoomRescanError.invalidCandidateGeometry
            }
            result.append(LayeredElement(element: element, layer: .object))
        }
        return result
    }

    private static func validate(
        element: RoomSemanticElement,
        layer: RoomRescanSemanticLayer,
        isCandidate: Bool
    ) throws {
        guard
            isSafeIdentifier(element.id),
            !element.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw isCandidate
                ? RoomRescanError.invalidCandidateGeometry
                : RoomRescanError.incompleteBijection
        }
        let dimensions = [
            element.dimensionsMeters.width,
            element.dimensionsMeters.height,
            element.dimensionsMeters.depth,
        ]
        guard dimensions.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw RoomRescanError.invalidCandidateGeometry
        }
        switch layer {
        case .structural:
            guard dimensions.filter({ $0 > 0 }).count >= 2, element.mobility != .movable else {
                throw RoomRescanError.invalidCandidateGeometry
            }
        case .object:
            guard dimensions.allSatisfy({ $0 > 0 }), element.mobility != .structural else {
                throw RoomRescanError.invalidCandidateGeometry
            }
        }
        if isCandidate {
            guard let transform = element.transform, isUsableCandidateTransform(transform) else {
                throw RoomRescanError.invalidCandidateGeometry
            }
        } else if element.transform?.isValid == false {
            throw RoomRescanError.invalidCandidateGeometry
        }
        guard element.polygonCorners?.allSatisfy(\.isFinite) != false else {
            throw RoomRescanError.invalidCandidateGeometry
        }
        guard isCandidate else {
            return
        }
        guard
            element.origin == .deterministicFixture,
            let provenance = element.provenance,
            !provenance.framework.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !provenance.sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            provenance.captureAttemptID == nil,
            provenance.coordinateSpaceEpochID == nil
        else {
            throw RoomRescanError.invalidCandidateGeometry
        }
    }

    /// Candidate transforms are column-major affine matrices. Require a
    /// homogeneous row approximately equal to `[0, 0, 0, 1]` and a
    /// nondegenerate 3x3 basis; accepting a merely finite 16-value matrix
    /// would let a singular or projective pose become durable revision data.
    private static func isUsableCandidateTransform(_ transform: RoomTransform4x4) -> Bool {
        guard transform.isValid else {
            return false
        }
        let values = transform.columnMajorValues
        guard
            abs(values[3]) <= candidateAffineTolerance,
            abs(values[7]) <= candidateAffineTolerance,
            abs(values[11]) <= candidateAffineTolerance,
            abs(values[15] - 1) <= candidateAffineTolerance
        else {
            return false
        }

        // Column-major matrix basis:
        // [0, 4, 8]
        // [1, 5, 9]
        // [2, 6, 10]
        let determinant =
            values[0] * (values[5] * values[10] - values[9] * values[6])
            - values[4] * (values[1] * values[10] - values[9] * values[2])
            + values[8] * (values[1] * values[6] - values[5] * values[2])
        return determinant.isFinite && abs(determinant) > candidateDeterminantTolerance
    }

    private static func validateExactBijection(
        matches: [RoomRescanElementMatch],
        baseElements: [LayeredElement],
        candidateElements: [LayeredElement]
    ) throws {
        guard matches.count == baseElements.count, matches.count == candidateElements.count else {
            throw RoomRescanError.incompleteBijection
        }
        let baseByID = Dictionary(uniqueKeysWithValues: baseElements.map { ($0.element.id, $0) })
        let candidateByID = Dictionary(uniqueKeysWithValues: candidateElements.map { ($0.element.id, $0) })
        var baseIDs = Set<String>()
        var candidateIDs = Set<String>()

        for match in matches {
            guard
                isSafeIdentifier(match.baseElementID),
                isSafeIdentifier(match.candidateElementID)
            else {
                throw RoomRescanError.incompleteBijection
            }
            guard
                baseIDs.insert(match.baseElementID).inserted,
                candidateIDs.insert(match.candidateElementID).inserted
            else {
                throw RoomRescanError.duplicateMatch
            }
            guard
                let base = baseByID[match.baseElementID],
                let candidate = candidateByID[match.candidateElementID]
            else {
                throw RoomRescanError.incompleteBijection
            }
            guard base.layer == match.baseLayer, candidate.layer == match.candidateLayer,
                  match.baseLayer == match.candidateLayer
            else {
                throw RoomRescanError.layerMismatch
            }
            guard
                base.element.kind == match.baseKind,
                candidate.element.kind == match.candidateKind,
                base.element.kind == candidate.element.kind
            else {
                throw RoomRescanError.kindMismatch
            }
        }
        guard baseIDs == Set(baseByID.keys), candidateIDs == Set(candidateByID.keys) else {
            throw RoomRescanError.incompleteBijection
        }
    }

    private static func resultElements(
        _ baseElements: [RoomSemanticElement],
        candidateByID: [String: LayeredElement],
        matchByBaseID: [String: RoomRescanElementMatch]
    ) throws -> [RoomSemanticElement] {
        try baseElements.map { base in
            guard
                let match = matchByBaseID[base.id],
                var candidate = candidateByID[match.candidateElementID]?.element
            else {
                throw RoomRescanError.incompleteBijection
            }
            // Durable IDs remain app-owned base IDs. Geometry and provenance
            // are the candidate's values, never a fused/averaged result.
            candidate.id = base.id
            candidate.origin = .deterministicFixture
            return candidate
        }
    }

    private static func makePreview(
        baseElements: [LayeredElement],
        resultElements: [LayeredElement]
    ) -> RoomRescanPreview {
        let resultByID = Dictionary(uniqueKeysWithValues: resultElements.map { ($0.element.id, $0.element) })
        var changes: [RoomRescanChange] = []
        for base in baseElements {
            guard let result = resultByID[base.element.id] else {
                continue
            }
            let id = base.element.id
            if base.element.transform != result.transform || base.element.polygonCorners != result.polygonCorners {
                changes.append(RoomRescanChange(
                    elementID: id,
                    kind: .pose,
                    oldValue: poseDescription(base.element),
                    newValue: poseDescription(result)
                ))
            }
            if base.element.dimensionsMeters != result.dimensionsMeters {
                changes.append(RoomRescanChange(
                    elementID: id,
                    kind: .dimensions,
                    oldValue: dimensionsDescription(base.element.dimensionsMeters),
                    newValue: dimensionsDescription(result.dimensionsMeters)
                ))
            }
            if base.element.kind != result.kind {
                changes.append(RoomRescanChange(
                    elementID: id,
                    kind: .category,
                    oldValue: base.element.kind,
                    newValue: result.kind
                ))
            }
            if base.element.label != result.label {
                changes.append(RoomRescanChange(
                    elementID: id,
                    kind: .label,
                    oldValue: base.element.label,
                    newValue: result.label
                ))
            }
            if base.element.provenance != result.provenance || base.element.mobility != result.mobility {
                changes.append(RoomRescanChange(
                    elementID: id,
                    kind: .semanticClassification,
                    oldValue: classificationDescription(base.element),
                    newValue: classificationDescription(result)
                ))
            }
        }
        return RoomRescanPreview(changes: changes)
    }

    private static func poseDescription(_ element: RoomSemanticElement) -> String {
        let transform = element.transform?.columnMajorValues.map { String(format: "%.4f", $0) }.joined(separator: ",") ?? "none"
        let polygon = element.polygonCorners?.count ?? 0
        return "transform=\(transform); polygonCorners=\(polygon)"
    }

    private static func dimensionsDescription(_ dimensions: RoomDimensions) -> String {
        String(
            format: "%.4f x %.4f x %.4f m",
            dimensions.width,
            dimensions.height,
            dimensions.depth
        )
    }

    private static func classificationDescription(_ element: RoomSemanticElement) -> String {
        let provenance = element.provenance
        return [
            element.mobility?.rawValue ?? "unspecified",
            provenance?.framework ?? "no-framework",
            provenance?.sourceIdentifier ?? "no-source",
            provenance?.classificationConfidence.rawValue ?? "unknown",
        ].joined(separator: " / ")
    }

    private static func matchOrder(
        _ lhs: RoomRescanElementMatch,
        _ rhs: RoomRescanElementMatch
    ) -> Bool {
        if lhs.baseElementID != rhs.baseElementID {
            return lhs.baseElementID < rhs.baseElementID
        }
        return lhs.candidateElementID < rhs.candidateElementID
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func normalized(_ snapshot: RoomSemanticSnapshot) -> RoomSemanticSnapshot {
        var normalized = snapshot
        normalized.structuralElements.sort { $0.id < $1.id }
        normalized.objectElements.sort { $0.id < $1.id }
        return normalized
    }
}
