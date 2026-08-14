import Foundation

/// Provider-neutral quality dimensions. They are deliberately independent:
/// none of these values is a survey, construction, or aggregate accuracy score.
public enum RoomQualityDimension: String, Codable, Sendable, Equatable, CaseIterable {
    case visualSharpness
    case spatialVisualCoverage
    case arTracking
    case semanticIdentificationConfidence
}

public enum RoomQualityDimensionState: String, Codable, Sendable, Equatable {
    case acceptable
    case advisory
    case unavailable
    case insufficientEvidence
}

public enum RoomQualityDisposition: String, Codable, Sendable, Equatable {
    case notice
    case revisitRecommended
    case stronglyRecommendRevisit
}

/// Stable, provider-neutral reason codes persisted in immutable revisions.
public enum RoomQualityReasonCode: String, Codable, Sendable, Equatable {
    case sharpnessAcceptable
    case blurredRegion
    case coverageAcceptable
    case weakCoverage
    case uncoveredRegion
    case trackingNormal
    case trackingLimited
    case semanticConfidenceAcceptable
    case semanticLowConfidence
    case sourceUnavailable
    case insufficientEvidence

    fileprivate func belongs(to dimension: RoomQualityDimension) -> Bool {
        switch (dimension, self) {
        case (.visualSharpness, .sharpnessAcceptable),
             (.visualSharpness, .blurredRegion),
             (.visualSharpness, .sourceUnavailable),
             (.visualSharpness, .insufficientEvidence),
             (.spatialVisualCoverage, .coverageAcceptable),
             (.spatialVisualCoverage, .weakCoverage),
             (.spatialVisualCoverage, .uncoveredRegion),
             (.spatialVisualCoverage, .sourceUnavailable),
             (.spatialVisualCoverage, .insufficientEvidence),
             (.arTracking, .trackingNormal),
             (.arTracking, .trackingLimited),
             (.arTracking, .sourceUnavailable),
             (.arTracking, .insufficientEvidence),
             (.semanticIdentificationConfidence, .semanticConfidenceAcceptable),
             (.semanticIdentificationConfidence, .semanticLowConfidence),
             (.semanticIdentificationConfidence, .sourceUnavailable),
             (.semanticIdentificationConfidence, .insufficientEvidence):
            return true
        default:
            return false
        }
    }

    fileprivate func belongs(to state: RoomQualityDimensionState) -> Bool {
        switch state {
        case .acceptable:
            return self == .sharpnessAcceptable
                || self == .coverageAcceptable
                || self == .trackingNormal
                || self == .semanticConfidenceAcceptable
        case .advisory:
            return self == .blurredRegion
                || self == .weakCoverage
                || self == .uncoveredRegion
                || self == .trackingLimited
                || self == .semanticLowConfidence
        case .unavailable:
            return self == .sourceUnavailable
        case .insufficientEvidence:
            return self == .insufficientEvidence
        }
    }
}

public enum RoomQualityEvidenceKind: String, Codable, Sendable, Equatable {
    case posedKeyframe
    case coverageProjection
    case trackingObservation
    case semanticElement
    case roomPlanCoaching
    case captureSummary
}

public struct RoomQualityEvidenceReference: Codable, Sendable, Equatable {
    public var evidenceID: String
    public var kind: RoomQualityEvidenceKind
    public var sourceReference: String
    public var sha256Hex: String?
    public var observedAt: Date?
    public var sampleCount: Int?

    public init(
        evidenceID: String,
        kind: RoomQualityEvidenceKind,
        sourceReference: String,
        sha256Hex: String? = nil,
        observedAt: Date? = nil,
        sampleCount: Int? = nil
    ) {
        self.evidenceID = evidenceID
        self.kind = kind
        self.sourceReference = sourceReference
        self.sha256Hex = sha256Hex
        self.observedAt = observedAt
        self.sampleCount = sampleCount
    }

    fileprivate func validate(at path: String) throws {
        try RoomQualityRules.identifier(evidenceID, at: "\(path).evidenceID")
        try RoomQualityRules.text(sourceReference, at: "\(path).sourceReference")
        if let sha256Hex {
            try RoomQualityRules.sha256(sha256Hex, at: "\(path).sha256Hex")
        }
        if let observedAt {
            try RoomQualityRules.date(observedAt, at: "\(path).observedAt")
        }
        if let sampleCount {
            guard (1...1_000_000).contains(sampleCount) else {
                throw RoomQualityRules.error("\(path).sampleCount", "Sample counts must be positive and bounded.")
            }
        }
    }
}

/// A bounded room-space region. It is qualitative localization, not a claim
/// of survey precision. The transform must be finite, affine, and nonsingular.
public struct RoomQualityRegion: Codable, Sendable, Equatable {
    public var regionID: String
    public var label: String
    public var semanticElementID: String?
    public var dimensionsMeters: RoomDimensions
    public var roomTransform: RoomTransform4x4

    public init(
        regionID: String,
        label: String,
        semanticElementID: String? = nil,
        dimensionsMeters: RoomDimensions,
        roomTransform: RoomTransform4x4
    ) throws {
        self.regionID = regionID
        self.label = label
        self.semanticElementID = semanticElementID
        self.dimensionsMeters = dimensionsMeters
        self.roomTransform = roomTransform
        try validate(at: "region")
    }

    fileprivate func validate(at path: String) throws {
        try RoomQualityRules.identifier(regionID, at: "\(path).regionID")
        try RoomQualityRules.text(label, at: "\(path).label")
        if let semanticElementID {
            try RoomQualityRules.identifier(semanticElementID, at: "\(path).semanticElementID")
        }
        let dimensions = [dimensionsMeters.width, dimensionsMeters.height, dimensionsMeters.depth]
        guard dimensions.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000 }) else {
            throw RoomQualityRules.error("\(path).dimensionsMeters", "Region dimensions must be finite and non-degenerate.")
        }
        guard RoomQualityRules.isFiniteAffineNonsingular(roomTransform) else {
            throw RoomQualityRules.error("\(path).roomTransform", "Region transforms must be finite, affine, and nonsingular.")
        }
    }
}

public struct RoomQualityFindingCandidate: Codable, Sendable, Equatable {
    public var findingID: String
    public var dimension: RoomQualityDimension
    public var reasonCode: RoomQualityReasonCode
    public var evidenceReferences: [RoomQualityEvidenceReference]
    public var affectedRegion: RoomQualityRegion?
    public var confidence: Double
    public var disposition: RoomQualityDisposition

    public init(
        findingID: String,
        dimension: RoomQualityDimension,
        reasonCode: RoomQualityReasonCode,
        evidenceReferences: [RoomQualityEvidenceReference],
        affectedRegion: RoomQualityRegion?,
        confidence: Double,
        disposition: RoomQualityDisposition
    ) {
        self.findingID = findingID
        self.dimension = dimension
        self.reasonCode = reasonCode
        self.evidenceReferences = evidenceReferences
        self.affectedRegion = affectedRegion
        self.confidence = confidence
        self.disposition = disposition
    }

    fileprivate func validate(at path: String) throws {
        try RoomQualityRules.identifier(findingID, at: "\(path).findingID")
        guard reasonCode.belongs(to: dimension), reasonCode.belongs(to: .advisory) else {
            throw RoomQualityRules.error("\(path).reasonCode", "Finding reason code is inconsistent with its quality dimension.")
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw RoomQualityRules.error("\(path).confidence", "Finding confidence must be finite and within 0...1.")
        }
        guard !evidenceReferences.isEmpty, evidenceReferences.count <= 1_000 else {
            throw RoomQualityRules.error("\(path).evidenceReferences", "Advisory findings require bounded evidence references.")
        }
        try RoomQualityRules.unique(evidenceReferences.map(\.evidenceID), at: "\(path).evidenceReferences")
        for (index, evidence) in evidenceReferences.enumerated() {
            try evidence.validate(at: "\(path).evidenceReferences[\(index)]")
        }
        try affectedRegion?.validate(at: "\(path).affectedRegion")
    }
}

public struct RoomQualityAssessmentRecord: Codable, Sendable, Equatable {
    public var dimension: RoomQualityDimension
    public var state: RoomQualityDimensionState
    public var reasonCode: RoomQualityReasonCode
    public var findings: [RoomQualityFindingCandidate]

    public init(
        dimension: RoomQualityDimension,
        state: RoomQualityDimensionState,
        reasonCode: RoomQualityReasonCode,
        findings: [RoomQualityFindingCandidate]
    ) {
        self.dimension = dimension
        self.state = state
        self.reasonCode = reasonCode
        self.findings = findings
    }

    fileprivate func validate(at path: String) throws {
        guard reasonCode.belongs(to: dimension), reasonCode.belongs(to: state) else {
            throw RoomQualityRules.error("\(path).reasonCode", "Record reason code is inconsistent with its state or dimension.")
        }
        if state == .advisory {
            guard !findings.isEmpty else {
                throw RoomQualityRules.error("\(path).findings", "Advisory records require at least one finding.")
            }
        } else if !findings.isEmpty {
            throw RoomQualityRules.error("\(path).findings", "Only advisory records may contain findings.")
        }
        try RoomQualityRules.unique(findings.map(\.findingID), at: "\(path).findings")
        for (index, finding) in findings.enumerated() {
            guard finding.dimension == dimension else {
                throw RoomQualityRules.error("\(path).findings[\(index)].dimension", "Finding and record dimensions must match.")
            }
            try finding.validate(at: "\(path).findings[\(index)]")
        }
    }
}

public struct RoomQualityAssessment: Codable, Sendable, Equatable {
    public var coordinateSpaceEpochID: String
    public var records: [RoomQualityAssessmentRecord]

    public init(coordinateSpaceEpochID: String, records: [RoomQualityAssessmentRecord]) {
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
        self.records = records
    }

    public var advisoryFindings: [RoomQualityFindingCandidate] {
        records.flatMap(\.findings).sorted(by: RoomQualityRules.findingOrder)
    }

    public func validate() throws {
        try RoomQualityRules.identifier(coordinateSpaceEpochID, at: "qualityAssessment.coordinateSpaceEpochID")
        guard records.map(\.dimension) == RoomQualityDimension.allCases else {
            throw RoomQualityRules.error("qualityAssessment.records", "Quality assessments require each independent dimension exactly once in canonical order.")
        }
        for (index, record) in records.enumerated() {
            try record.validate(at: "qualityAssessment.records[\(index)]")
        }
        try RoomQualityRules.unique(advisoryFindings.map(\.findingID), at: "qualityAssessment.findings")
    }

    public func bind(
        projectID: String,
        revisionID: String,
        generatedAt: Date,
        acknowledgement: RoomQualitySaveAnywayAcknowledgementRequest?
    ) throws -> RoomQualityReport {
        try validate()
        try RoomQualityRules.identifier(projectID, at: "qualityReport.projectID")
        try RoomQualityRules.identifier(revisionID, at: "qualityReport.revisionID")
        try RoomQualityRules.date(generatedAt, at: "qualityReport.generatedAt")

        let eligibility = RoomQualityFinishGate.eligibility(for: self)
        let expectedFindingIDs = RoomQualityRules.acknowledgementIDs(records)
        let expectedWarningDigest = try RoomQualityRules.warningDigest(records)
        let persistedAcknowledgement: RoomQualitySaveAnywayAcknowledgement?
        switch eligibility {
        case .proceedNormally:
            guard acknowledgement == nil else {
                throw RoomQualityRules.error("qualityReport.saveAcknowledgement", "An acceptable scan must not fabricate a Save Anyway acknowledgement.")
            }
            persistedAcknowledgement = nil
        case .reviewRecommended:
            guard let acknowledgement else {
                throw RoomQualityRules.error("qualityReport.saveAcknowledgement", "A weak scan requires explicit Save Anyway acknowledgement.")
            }
            try acknowledgement.validate()
            guard acknowledgement.acknowledgedFindingIDs == expectedFindingIDs,
                  acknowledgement.warningDigestSHA256 == expectedWarningDigest
            else {
                throw RoomQualityRules.error("qualityReport.saveAcknowledgement", "Save Anyway must acknowledge the exact canonical warning set.")
            }
            persistedAcknowledgement = RoomQualitySaveAnywayAcknowledgement(
                action: .saveAnyway,
                acknowledgedAt: acknowledgement.acknowledgedAt,
                acknowledgedFindingIDs: acknowledgement.acknowledgedFindingIDs,
                warningDigestSHA256: acknowledgement.warningDigestSHA256,
                projectID: projectID,
                revisionID: revisionID,
                coordinateSpaceEpochID: coordinateSpaceEpochID
            )
        }

        let boundRecords = records.map { record in
            RoomQualityDimensionRecord(
                dimension: record.dimension,
                state: record.state,
                reasonCode: record.reasonCode,
                findings: record.findings.map { candidate in
                    RoomQualityFinding(
                        findingID: candidate.findingID,
                        dimension: candidate.dimension,
                        reasonCode: candidate.reasonCode,
                        evidenceReferences: candidate.evidenceReferences,
                        affectedRegion: candidate.affectedRegion,
                        confidence: candidate.confidence,
                        disposition: candidate.disposition,
                        projectID: projectID,
                        revisionID: revisionID,
                        coordinateSpaceEpochID: coordinateSpaceEpochID
                    )
                }
            )
        }
        let report = RoomQualityReport(
            projectID: projectID,
            revisionID: revisionID,
            coordinateSpaceEpochID: coordinateSpaceEpochID,
            generatedAt: generatedAt,
            records: boundRecords,
            finishEligibility: eligibility,
            saveAcknowledgement: persistedAcknowledgement
        )
        try report.validate()
        return report
    }
}

public enum RoomQualityFinishEligibility: String, Codable, Sendable, Equatable {
    case proceedNormally
    case reviewRecommended
}

public enum RoomQualityFinishGate {
    public static func eligibility(for assessment: RoomQualityAssessment) -> RoomQualityFinishEligibility {
        assessment.records.allSatisfy { $0.state == .acceptable }
            ? .proceedNormally
            : .reviewRecommended
    }
}

public enum RoomQualitySaveAction: String, Codable, Sendable, Equatable {
    case saveAnyway
}

public struct RoomQualitySaveAnywayAcknowledgementRequest: Codable, Sendable, Equatable {
    public var action: RoomQualitySaveAction
    public var acknowledgedAt: Date
    public var acknowledgedFindingIDs: [String]
    public var warningDigestSHA256: String

    public init(
        action: RoomQualitySaveAction = .saveAnyway,
        acknowledgedAt: Date,
        acknowledgedFindingIDs: [String],
        warningDigestSHA256: String
    ) {
        self.action = action
        self.acknowledgedAt = acknowledgedAt
        self.acknowledgedFindingIDs = acknowledgedFindingIDs
        self.warningDigestSHA256 = warningDigestSHA256
    }

    public static func make(
        for assessment: RoomQualityAssessment,
        acknowledgedAt: Date
    ) throws -> Self {
        try assessment.validate()
        return .init(
            acknowledgedAt: acknowledgedAt,
            acknowledgedFindingIDs: RoomQualityRules.acknowledgementIDs(assessment.records),
            warningDigestSHA256: try RoomQualityRules.warningDigest(assessment.records)
        )
    }

    fileprivate func validate() throws {
        try RoomQualityRules.date(acknowledgedAt, at: "saveAcknowledgement.acknowledgedAt")
        try RoomQualityRules.unique(acknowledgedFindingIDs, at: "saveAcknowledgement.acknowledgedFindingIDs")
        for identifier in acknowledgedFindingIDs {
            try RoomQualityRules.identifier(identifier, at: "saveAcknowledgement.acknowledgedFindingIDs")
        }
        try RoomQualityRules.sha256(warningDigestSHA256, at: "saveAcknowledgement.warningDigestSHA256")
    }
}

public struct RoomQualitySaveAnywayAcknowledgement: Codable, Sendable, Equatable {
    public var action: RoomQualitySaveAction
    public var acknowledgedAt: Date
    public var acknowledgedFindingIDs: [String]
    public var warningDigestSHA256: String
    public var projectID: String
    public var revisionID: String
    public var coordinateSpaceEpochID: String
}

public struct RoomQualityFinding: Codable, Sendable, Equatable {
    public var findingID: String
    public var dimension: RoomQualityDimension
    public var reasonCode: RoomQualityReasonCode
    public var evidenceReferences: [RoomQualityEvidenceReference]
    public var affectedRegion: RoomQualityRegion?
    public var confidence: Double
    public var disposition: RoomQualityDisposition
    public var projectID: String
    public var revisionID: String
    public var coordinateSpaceEpochID: String

    fileprivate func candidate() -> RoomQualityFindingCandidate {
        .init(
            findingID: findingID,
            dimension: dimension,
            reasonCode: reasonCode,
            evidenceReferences: evidenceReferences,
            affectedRegion: affectedRegion,
            confidence: confidence,
            disposition: disposition
        )
    }
}

public struct RoomQualityDimensionRecord: Codable, Sendable, Equatable {
    public var dimension: RoomQualityDimension
    public var state: RoomQualityDimensionState
    public var reasonCode: RoomQualityReasonCode
    public var findings: [RoomQualityFinding]
}

/// Canonical quality report persisted as part of one immutable revision.
/// The optional revision hook keeps every pre-Slice-2 package decodable.
public struct RoomQualityReport: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var projectID: String
    public var revisionID: String
    public var coordinateSpaceEpochID: String
    public var generatedAt: Date
    public var records: [RoomQualityDimensionRecord]
    public var finishEligibility: RoomQualityFinishEligibility
    public var saveAcknowledgement: RoomQualitySaveAnywayAcknowledgement?

    public init(
        schemaVersion: String = "roomscan-quality-report-v1",
        projectID: String,
        revisionID: String,
        coordinateSpaceEpochID: String,
        generatedAt: Date,
        records: [RoomQualityDimensionRecord],
        finishEligibility: RoomQualityFinishEligibility,
        saveAcknowledgement: RoomQualitySaveAnywayAcknowledgement?
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.revisionID = revisionID
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
        self.generatedAt = generatedAt
        self.records = records
        self.finishEligibility = finishEligibility
        self.saveAcknowledgement = saveAcknowledgement
    }

    public func validate(
        expectedProjectID: String? = nil,
        expectedRevisionID: String? = nil,
        expectedCoordinateSpaceEpochID: String? = nil
    ) throws {
        guard schemaVersion == "roomscan-quality-report-v1" else {
            throw RoomQualityRules.error("qualityReport.schemaVersion", "Unsupported quality report schema.")
        }
        try RoomQualityRules.identifier(projectID, at: "qualityReport.projectID")
        try RoomQualityRules.identifier(revisionID, at: "qualityReport.revisionID")
        try RoomQualityRules.identifier(coordinateSpaceEpochID, at: "qualityReport.coordinateSpaceEpochID")
        try RoomQualityRules.date(generatedAt, at: "qualityReport.generatedAt")
        guard expectedProjectID.map({ $0 == projectID }) ?? true,
              expectedRevisionID.map({ $0 == revisionID }) ?? true,
              expectedCoordinateSpaceEpochID.map({ $0 == coordinateSpaceEpochID }) ?? true
        else {
            throw RoomQualityRules.error("qualityReport.binding", "Quality reports cannot be rebound to another project, revision, or coordinate-space epoch.")
        }
        guard records.map(\.dimension) == RoomQualityDimension.allCases else {
            throw RoomQualityRules.error("qualityReport.records", "Quality reports require each independent dimension exactly once in canonical order.")
        }

        var allFindings: [RoomQualityFinding] = []
        for (recordIndex, record) in records.enumerated() {
            let path = "qualityReport.records[\(recordIndex)]"
            guard record.reasonCode.belongs(to: record.dimension), record.reasonCode.belongs(to: record.state) else {
                throw RoomQualityRules.error("\(path).reasonCode", "Record reason code is inconsistent with its state or dimension.")
            }
            if record.state == .advisory {
                guard !record.findings.isEmpty else {
                    throw RoomQualityRules.error("\(path).findings", "Advisory records require findings.")
                }
            } else if !record.findings.isEmpty {
                throw RoomQualityRules.error("\(path).findings", "Only advisory records may contain findings.")
            }
            for (findingIndex, finding) in record.findings.enumerated() {
                let findingPath = "\(path).findings[\(findingIndex)]"
                guard finding.dimension == record.dimension,
                      finding.projectID == projectID,
                      finding.revisionID == revisionID,
                      finding.coordinateSpaceEpochID == coordinateSpaceEpochID
                else {
                    throw RoomQualityRules.error("\(findingPath).binding", "Every finding must retain the report's exact dimension and source binding.")
                }
                try finding.candidate().validate(at: findingPath)
                allFindings.append(finding)
            }
        }
        try RoomQualityRules.unique(allFindings.map(\.findingID), at: "qualityReport.findings")
        let sortedFindings = allFindings.sorted { RoomQualityRules.findingOrder($0.candidate(), $1.candidate()) }
        guard allFindings == sortedFindings else {
            throw RoomQualityRules.error("qualityReport.findings", "Findings must use canonical deterministic order.")
        }

        let expectedEligibility: RoomQualityFinishEligibility = records.allSatisfy { $0.state == .acceptable }
            ? .proceedNormally
            : .reviewRecommended
        guard finishEligibility == expectedEligibility else {
            throw RoomQualityRules.error("qualityReport.finishEligibility", "Finish eligibility must be derived from all four independent records.")
        }
        if expectedEligibility == .proceedNormally {
            guard saveAcknowledgement == nil else {
                throw RoomQualityRules.error("qualityReport.saveAcknowledgement", "An acceptable scan must not contain a Save Anyway acknowledgement.")
            }
        } else {
            guard let saveAcknowledgement else {
                throw RoomQualityRules.error("qualityReport.saveAcknowledgement", "A review-recommended scan requires explicit Save Anyway acknowledgement before persistence.")
            }
            try RoomQualityRules.date(saveAcknowledgement.acknowledgedAt, at: "qualityReport.saveAcknowledgement.acknowledgedAt")
            let assessmentRecords = records.map { record in
                RoomQualityAssessmentRecord(
                    dimension: record.dimension,
                    state: record.state,
                    reasonCode: record.reasonCode,
                    findings: record.findings.map { $0.candidate() }
                )
            }
            let expectedWarningDigest = try RoomQualityRules.warningDigest(assessmentRecords)
            guard saveAcknowledgement.action == .saveAnyway,
                  saveAcknowledgement.projectID == projectID,
                  saveAcknowledgement.revisionID == revisionID,
                  saveAcknowledgement.coordinateSpaceEpochID == coordinateSpaceEpochID,
                  saveAcknowledgement.acknowledgedFindingIDs == RoomQualityRules.acknowledgementIDs(assessmentRecords),
                  saveAcknowledgement.warningDigestSHA256 == expectedWarningDigest
            else {
                throw RoomQualityRules.error("qualityReport.saveAcknowledgement", "Save Anyway provenance must match the exact report binding and warning set.")
            }
        }
    }
}

/// Strict standalone decoder for the canonical report bytes future package
/// and snapshot carriers will embed unchanged. Noncanonical, duplicate, or
/// unknown-member input cannot round-trip to identical bytes and fails closed.
public enum RoomQualityReportDecoder {
    public static func decodeCanonical(_ data: Data) throws -> RoomQualityReport {
        let report: RoomQualityReport
        do {
            report = try RoomJSONCoding.makeDecoder().decode(RoomQualityReport.self, from: data)
            try report.validate()
        } catch let error as RoomRedesignContractValidationError {
            throw error
        } catch {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        guard try RoomRedesignCanonicalJSON.encode(report) == data else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "qualityReport",
                reason: "Quality report bytes must be canonical and contain no unknown or duplicate members."
            )
        }
        return report
    }
}

/// Provider-neutral hook only: Slice 3 AI archives and Slice 6 snapshots may
/// carry this exact report and digest, but this slice creates no archive,
/// upload, publication, authentication, or hosted route.
public struct RoomQualityReportCarrierV1: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var sourceRevision: RoomRedesignSourceRevision
    public var qualityReport: RoomQualityReport
    public var qualityReportSHA256: String

    public init(
        schemaVersion: String = "roomscan-quality-report-carrier-v1",
        sourceRevision: RoomRedesignSourceRevision,
        qualityReport: RoomQualityReport,
        qualityReportSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRevision = sourceRevision
        self.qualityReport = qualityReport
        self.qualityReportSHA256 = qualityReportSHA256
    }

    public func validate() throws {
        guard schemaVersion == "roomscan-quality-report-carrier-v1" else {
            throw RoomQualityRules.error("qualityCarrier.schemaVersion", "Unsupported quality carrier schema.")
        }
        try sourceRevision.validate()
        try qualityReport.validate(
            expectedProjectID: sourceRevision.projectID,
            expectedRevisionID: sourceRevision.revisionID,
            expectedCoordinateSpaceEpochID: sourceRevision.coordinateSpaceEpochID
        )
        let expectedDigest = try RoomRedesignCanonicalJSON.sha256(qualityReport)
        guard qualityReportSHA256 == expectedDigest else {
            throw RoomQualityRules.error("qualityCarrier.qualityReportSHA256", "Carrier digest must match the unchanged canonical quality report.")
        }
    }
}

// MARK: - Deterministic aggregation

public struct RoomQualityFrameEvidence: Codable, Sendable, Equatable {
    public var evidence: RoomQualityEvidenceReference
    public var rawSharpness: Double
    public var visibleRegionIDs: [String]

    public init(
        evidence: RoomQualityEvidenceReference,
        rawSharpness: Double,
        visibleRegionIDs: [String]
    ) {
        self.evidence = evidence
        self.rawSharpness = rawSharpness
        self.visibleRegionIDs = visibleRegionIDs
    }
}

public struct RoomQualityTrackingEvidence: Codable, Sendable, Equatable {
    public var evidence: RoomQualityEvidenceReference
    public var quality: RoomTrackingQuality
    public var limitedReason: RoomTrackingLimitedReason?
    public var affectedRegionID: String?

    public init(
        evidence: RoomQualityEvidenceReference,
        quality: RoomTrackingQuality,
        limitedReason: RoomTrackingLimitedReason?,
        affectedRegionID: String?
    ) {
        self.evidence = evidence
        self.quality = quality
        self.limitedReason = limitedReason
        self.affectedRegionID = affectedRegionID
    }
}

public struct RoomQualityCoverageEvidence: Codable, Sendable, Equatable {
    public var evidence: RoomQualityEvidenceReference
    public var visibleRegionIDs: [String]

    public init(evidence: RoomQualityEvidenceReference, visibleRegionIDs: [String]) {
        self.evidence = evidence
        self.visibleRegionIDs = visibleRegionIDs
    }
}

public struct RoomQualitySemanticEvidence: Codable, Sendable, Equatable {
    public var evidence: RoomQualityEvidenceReference
    public var classificationConfidence: RoomClassificationConfidence
    public var affectedRegionID: String?

    public init(
        evidence: RoomQualityEvidenceReference,
        classificationConfidence: RoomClassificationConfidence,
        affectedRegionID: String?
    ) {
        self.evidence = evidence
        self.classificationConfidence = classificationConfidence
        self.affectedRegionID = affectedRegionID
    }
}

public struct RoomQualityAggregationInput: Codable, Sendable, Equatable {
    public var coordinateSpaceEpochID: String
    public var regions: [RoomQualityRegion]
    public var frames: [RoomQualityFrameEvidence]
    public var tracking: [RoomQualityTrackingEvidence]
    public var semantics: [RoomQualitySemanticEvidence]
    public var coverageFrames: [RoomQualityCoverageEvidence]?
    public var visualSourceAvailable: Bool
    public var coverageSourceAvailable: Bool

    public init(
        coordinateSpaceEpochID: String,
        regions: [RoomQualityRegion],
        frames: [RoomQualityFrameEvidence],
        tracking: [RoomQualityTrackingEvidence],
        semantics: [RoomQualitySemanticEvidence],
        coverageFrames: [RoomQualityCoverageEvidence]? = nil,
        visualSourceAvailable: Bool = true,
        coverageSourceAvailable: Bool = true
    ) {
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
        self.regions = regions
        self.frames = frames
        self.tracking = tracking
        self.semantics = semantics
        self.coverageFrames = coverageFrames
        self.visualSourceAvailable = visualSourceAvailable
        self.coverageSourceAvailable = coverageSourceAvailable
    }
}

public enum RoomQualityAggregator {
    public static func aggregate(_ input: RoomQualityAggregationInput) throws -> RoomQualityAssessment {
        try validate(input)
        let regions = Dictionary(uniqueKeysWithValues: input.regions.map { ($0.regionID, $0) })
        let records = [
            sharpnessRecord(input: input, regions: regions),
            coverageRecord(input: input, regions: regions),
            trackingRecord(input: input, regions: regions),
            semanticRecord(input: input, regions: regions),
        ]
        let assessment = RoomQualityAssessment(
            coordinateSpaceEpochID: input.coordinateSpaceEpochID,
            records: records
        )
        try assessment.validate()
        return assessment
    }

    private static func validate(_ input: RoomQualityAggregationInput) throws {
        try RoomQualityRules.identifier(input.coordinateSpaceEpochID, at: "qualityInput.coordinateSpaceEpochID")
        guard input.regions.count <= 1_000, input.frames.count <= 10_000,
              input.tracking.count <= 10_000, input.semantics.count <= 10_000,
              (input.coverageFrames?.count ?? 0) <= 10_000
        else {
            throw RoomQualityRules.error("qualityInput", "Quality input collections must be bounded.")
        }
        try RoomQualityRules.unique(input.regions.map(\.regionID), at: "qualityInput.regions")
        let regionIDs = Set(input.regions.map(\.regionID))
        for (index, region) in input.regions.enumerated() {
            try region.validate(at: "qualityInput.regions[\(index)]")
        }
        for (index, frame) in input.frames.enumerated() {
            try frame.evidence.validate(at: "qualityInput.frames[\(index)].evidence")
            guard frame.evidence.kind == .posedKeyframe,
                  frame.rawSharpness.isFinite,
                  frame.rawSharpness >= 0
            else {
                throw RoomQualityRules.error("qualityInput.frames[\(index)]", "Frame evidence requires a finite non-negative sharpness score from a posed keyframe.")
            }
            try RoomQualityRules.unique(frame.visibleRegionIDs, at: "qualityInput.frames[\(index)].visibleRegionIDs")
            guard frame.visibleRegionIDs.allSatisfy(regionIDs.contains) else {
                throw RoomQualityRules.error("qualityInput.frames[\(index)].visibleRegionIDs", "Frame evidence cannot reference an unknown or rebound region.")
            }
        }
        for (index, frame) in (input.coverageFrames ?? []).enumerated() {
            try frame.evidence.validate(at: "qualityInput.coverageFrames[\(index)].evidence")
            guard frame.evidence.kind == .coverageProjection || frame.evidence.kind == .posedKeyframe else {
                throw RoomQualityRules.error("qualityInput.coverageFrames[\(index)].evidence.kind", "Coverage evidence must derive from a coverage projection or posed keyframe.")
            }
            try RoomQualityRules.unique(frame.visibleRegionIDs, at: "qualityInput.coverageFrames[\(index)].visibleRegionIDs")
            guard frame.visibleRegionIDs.allSatisfy(regionIDs.contains) else {
                throw RoomQualityRules.error("qualityInput.coverageFrames[\(index)].visibleRegionIDs", "Coverage evidence cannot reference an unknown or rebound region.")
            }
        }
        for (index, tracking) in input.tracking.enumerated() {
            try tracking.evidence.validate(at: "qualityInput.tracking[\(index)].evidence")
            guard tracking.evidence.kind == .trackingObservation else {
                throw RoomQualityRules.error("qualityInput.tracking[\(index)].evidence.kind", "Tracking evidence must use the tracking observation kind.")
            }
            guard tracking.affectedRegionID.map(regionIDs.contains) ?? true else {
                throw RoomQualityRules.error("qualityInput.tracking[\(index)].affectedRegionID", "Tracking evidence cannot reference an unknown or rebound region.")
            }
            guard tracking.quality == .limited || tracking.limitedReason == nil else {
                throw RoomQualityRules.error("qualityInput.tracking[\(index)].limitedReason", "Only limited tracking may carry a limited reason.")
            }
        }
        for (index, semantic) in input.semantics.enumerated() {
            try semantic.evidence.validate(at: "qualityInput.semantics[\(index)].evidence")
            guard semantic.evidence.kind == .semanticElement else {
                throw RoomQualityRules.error("qualityInput.semantics[\(index)].evidence.kind", "Semantic evidence must use the semantic element kind.")
            }
            guard semantic.affectedRegionID.map(regionIDs.contains) ?? true else {
                throw RoomQualityRules.error("qualityInput.semantics[\(index)].affectedRegionID", "Semantic evidence cannot reference an unknown or rebound region.")
            }
        }
    }

    private static func sharpnessRecord(
        input: RoomQualityAggregationInput,
        regions: [String: RoomQualityRegion]
    ) -> RoomQualityAssessmentRecord {
        guard input.visualSourceAvailable else {
            return .init(dimension: .visualSharpness, state: .unavailable, reasonCode: .sourceUnavailable, findings: [])
        }
        guard input.frames.count >= 3, !regions.isEmpty else {
            return .init(dimension: .visualSharpness, state: .insufficientEvidence, reasonCode: .insufficientEvidence, findings: [])
        }
        let normalized = RoomMeshFrameAnalysis.normalizedSharpness(input.frames.map(\.rawSharpness))
        var findings: [RoomQualityFindingCandidate] = []
        for regionID in regions.keys.sorted() {
            let indices = input.frames.indices.filter { input.frames[$0].visibleRegionIDs.contains(regionID) }
            guard !indices.isEmpty else { continue }
            let weakest = indices.min { normalized[$0] < normalized[$1] }!
            guard normalized[weakest] < 0.65 else { continue }
            findings.append(.init(
                findingID: "sharpness-\(regionID)",
                dimension: .visualSharpness,
                reasonCode: .blurredRegion,
                evidenceReferences: [input.frames[weakest].evidence],
                affectedRegion: regions[regionID],
                confidence: min(1, max(0.5, 1 - normalized[weakest] / 2)),
                disposition: .revisitRecommended
            ))
        }
        return findings.isEmpty
            ? .init(dimension: .visualSharpness, state: .acceptable, reasonCode: .sharpnessAcceptable, findings: [])
            : .init(dimension: .visualSharpness, state: .advisory, reasonCode: .blurredRegion, findings: findings)
    }

    private static func coverageRecord(
        input: RoomQualityAggregationInput,
        regions: [String: RoomQualityRegion]
    ) -> RoomQualityAssessmentRecord {
        guard input.coverageSourceAvailable else {
            return .init(dimension: .spatialVisualCoverage, state: .unavailable, reasonCode: .sourceUnavailable, findings: [])
        }
        let coverageFrames = input.coverageFrames
            ?? input.frames.map { .init(evidence: $0.evidence, visibleRegionIDs: $0.visibleRegionIDs) }
        guard coverageFrames.count >= 3, !regions.isEmpty else {
            return .init(dimension: .spatialVisualCoverage, state: .insufficientEvidence, reasonCode: .insufficientEvidence, findings: [])
        }
        var findings: [RoomQualityFindingCandidate] = []
        for regionID in regions.keys.sorted() {
            let frames = coverageFrames.filter { $0.visibleRegionIDs.contains(regionID) }
            guard frames.count < 2 else { continue }
            let reason: RoomQualityReasonCode = frames.isEmpty ? .uncoveredRegion : .weakCoverage
            let evidence = frames.first?.evidence ?? RoomQualityEvidenceReference(
                evidenceID: "coverage-\(regionID)",
                kind: .coverageProjection,
                sourceReference: "coverage-summary-\(regionID)",
                sampleCount: coverageFrames.count
            )
            findings.append(.init(
                findingID: "coverage-\(regionID)",
                dimension: .spatialVisualCoverage,
                reasonCode: reason,
                evidenceReferences: [evidence],
                affectedRegion: regions[regionID],
                confidence: frames.isEmpty ? 0.9 : 0.75,
                disposition: frames.isEmpty ? .stronglyRecommendRevisit : .revisitRecommended
            ))
        }
        return findings.isEmpty
            ? .init(dimension: .spatialVisualCoverage, state: .acceptable, reasonCode: .coverageAcceptable, findings: [])
            : .init(dimension: .spatialVisualCoverage, state: .advisory, reasonCode: findings[0].reasonCode, findings: findings)
    }

    private static func trackingRecord(
        input: RoomQualityAggregationInput,
        regions: [String: RoomQualityRegion]
    ) -> RoomQualityAssessmentRecord {
        guard !input.tracking.isEmpty else {
            return .init(dimension: .arTracking, state: .insufficientEvidence, reasonCode: .insufficientEvidence, findings: [])
        }
        let limited = input.tracking.filter { $0.quality == .limited || $0.quality == .notAvailable }
        if !limited.isEmpty {
            let findings = limited.enumerated().map { index, observation in
                let suffix = observation.affectedRegionID ?? String(format: "%03d", index + 1)
                return RoomQualityFindingCandidate(
                    findingID: "tracking-\(suffix)",
                    dimension: .arTracking,
                    reasonCode: .trackingLimited,
                    evidenceReferences: [observation.evidence],
                    affectedRegion: observation.affectedRegionID.flatMap { regions[$0] },
                    confidence: observation.quality == .notAvailable ? 0.6 : 0.85,
                    disposition: .revisitRecommended
                )
            }.sorted(by: RoomQualityRules.findingOrder)
            return .init(dimension: .arTracking, state: .advisory, reasonCode: .trackingLimited, findings: findings)
        }
        guard input.tracking.contains(where: { $0.quality == .normal }) else {
            return .init(dimension: .arTracking, state: .insufficientEvidence, reasonCode: .insufficientEvidence, findings: [])
        }
        return .init(dimension: .arTracking, state: .acceptable, reasonCode: .trackingNormal, findings: [])
    }

    private static func semanticRecord(
        input: RoomQualityAggregationInput,
        regions: [String: RoomQualityRegion]
    ) -> RoomQualityAssessmentRecord {
        guard !input.semantics.isEmpty else {
            return .init(dimension: .semanticIdentificationConfidence, state: .insufficientEvidence, reasonCode: .insufficientEvidence, findings: [])
        }
        let low = input.semantics.filter { $0.classificationConfidence == .low }
        if !low.isEmpty {
            let findings = low.enumerated().map { index, observation in
                let suffix = observation.affectedRegionID ?? String(format: "%03d", index + 1)
                return RoomQualityFindingCandidate(
                    findingID: "semantic-\(suffix)",
                    dimension: .semanticIdentificationConfidence,
                    reasonCode: .semanticLowConfidence,
                    evidenceReferences: [observation.evidence],
                    affectedRegion: observation.affectedRegionID.flatMap { regions[$0] },
                    confidence: 0.75,
                    disposition: .revisitRecommended
                )
            }.sorted(by: RoomQualityRules.findingOrder)
            return .init(
                dimension: .semanticIdentificationConfidence,
                state: .advisory,
                reasonCode: .semanticLowConfidence,
                findings: findings
            )
        }
        guard input.semantics.contains(where: { $0.classificationConfidence == .medium || $0.classificationConfidence == .high }) else {
            return .init(dimension: .semanticIdentificationConfidence, state: .insufficientEvidence, reasonCode: .insufficientEvidence, findings: [])
        }
        return .init(
            dimension: .semanticIdentificationConfidence,
            state: .acceptable,
            reasonCode: .semanticConfidenceAcceptable,
            findings: []
        )
    }
}

// MARK: - Bounded live coaching

public struct RoomQualityCoachingCue: Codable, Sendable, Equatable {
    public var dimension: RoomQualityDimension
    public var reasonCode: RoomQualityReasonCode
    public var affectedRegion: RoomQualityRegion?
    public var disposition: RoomQualityDisposition

    public init(
        dimension: RoomQualityDimension,
        reasonCode: RoomQualityReasonCode,
        affectedRegion: RoomQualityRegion?,
        disposition: RoomQualityDisposition
    ) {
        self.dimension = dimension
        self.reasonCode = reasonCode
        self.affectedRegion = affectedRegion
        self.disposition = disposition
    }

    fileprivate var key: String {
        "\(dimension.rawValue)|\(reasonCode.rawValue)|\(affectedRegion?.regionID ?? "general")|\(disposition.rawValue)"
    }
}

public struct RoomQualityCoachingThrottle: Sendable {
    public let minimumSequenceInterval: UInt64
    public let maximumVisibleCues: Int
    private var visibleKeys: [String] = []
    private var lastEmissionByKey: [String: UInt64] = [:]

    public init(minimumSequenceInterval: UInt64, maximumVisibleCues: Int) {
        self.minimumSequenceInterval = max(1, minimumSequenceInterval)
        self.maximumVisibleCues = min(max(1, maximumVisibleCues), 8)
    }

    public mutating func update(
        candidates: [RoomQualityCoachingCue],
        sequence: UInt64
    ) -> [RoomQualityCoachingCue]? {
        let ordered = candidates.sorted { lhs, rhs in
            if RoomQualityRules.dimensionIndex(lhs.dimension) != RoomQualityRules.dimensionIndex(rhs.dimension) {
                return RoomQualityRules.dimensionIndex(lhs.dimension) < RoomQualityRules.dimensionIndex(rhs.dimension)
            }
            return lhs.key < rhs.key
        }
        var seen = Set<String>()
        let unique = ordered.filter { seen.insert($0.key).inserted }.prefix(maximumVisibleCues)
        let bounded = Array(unique)
        let keys = bounded.map(\.key)
        guard keys != visibleKeys else { return nil }

        if !keys.isEmpty {
            let tooSoon = keys.contains { key in
                guard let last = lastEmissionByKey[key], sequence >= last else { return false }
                return sequence - last < minimumSequenceInterval
            }
            guard !tooSoon else { return nil }
        }
        visibleKeys = keys
        for key in keys { lastEmissionByKey[key] = sequence }
        return bounded
    }
}

private enum RoomQualityRules {
    static func error(_ path: String, _ reason: String) -> RoomRedesignContractValidationError {
        .invalidValue(path: path, reason: reason)
    }

    static func identifier(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw error(path, "Value must be a stable ASCII identifier.")
        }
    }

    static func text(_ value: String, at path: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= 512,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw error(path, "Text must be non-empty, bounded, and free of control characters.")
        }
    }

    static func sha256(_ value: String, at path: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.count == 64, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw error(path, "Value must be a lowercase 64-character SHA-256 digest.")
        }
    }

    static func date(_ value: Date, at path: String) throws {
        guard value.timeIntervalSince1970.isFinite else {
            throw error(path, "Date must be finite.")
        }
    }

    static func unique(_ values: [String], at path: String) throws {
        guard Set(values).count == values.count else {
            throw error(path, "Values must be unique.")
        }
    }

    static func isFiniteAffineNonsingular(_ transform: RoomTransform4x4) -> Bool {
        let m = transform.columnMajorValues
        guard m.count == 16, m.allSatisfy(\.isFinite),
              abs(m[3]) <= 1e-9, abs(m[7]) <= 1e-9,
              abs(m[11]) <= 1e-9, abs(m[15] - 1) <= 1e-9,
              abs(m[12]) <= 10_000, abs(m[13]) <= 10_000, abs(m[14]) <= 10_000
        else { return false }
        let determinant = m[0] * (m[5] * m[10] - m[9] * m[6])
            - m[4] * (m[1] * m[10] - m[9] * m[2])
            + m[8] * (m[1] * m[6] - m[5] * m[2])
        return determinant.isFinite && abs(determinant) > 1e-9
    }

    static func dimensionIndex(_ dimension: RoomQualityDimension) -> Int {
        RoomQualityDimension.allCases.firstIndex(of: dimension) ?? .max
    }

    static func findingOrder(_ lhs: RoomQualityFindingCandidate, _ rhs: RoomQualityFindingCandidate) -> Bool {
        let lhsIndex = dimensionIndex(lhs.dimension)
        let rhsIndex = dimensionIndex(rhs.dimension)
        return lhsIndex == rhsIndex ? lhs.findingID < rhs.findingID : lhsIndex < rhsIndex
    }

    static func acknowledgementIDs(_ records: [RoomQualityAssessmentRecord]) -> [String] {
        records.flatMap { record -> [String] in
            switch record.state {
            case .acceptable:
                return []
            case .advisory:
                return record.findings.sorted(by: findingOrder).map(\.findingID)
            case .unavailable, .insufficientEvidence:
                return ["quality-\(record.dimension.rawValue)-\(record.state.rawValue)"]
            }
        }
    }

    static func warningDigest(_ records: [RoomQualityAssessmentRecord]) throws -> String {
        try RoomRedesignCanonicalJSON.sha256(records.filter { $0.state != .acceptable })
    }
}
