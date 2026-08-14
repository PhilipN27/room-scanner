import XCTest
@testable import RoomScanCore

final class RoomQualityTests: XCTestCase {
    func testDeterministicQualityFixtureMatrixTriggersOnlyIntendedDimensions() throws {
        let matrix = try loadFixtureMatrix()
        for scenario in matrix.validScenarios {
            let assessment = try RoomQualityAggregator.aggregate(
                aggregationInput(mode: scenario.mode)
            )
            XCTAssertEqual(
                assessment.advisoryFindings.map(\.dimension),
                scenario.expectedAdvisoryDimensions,
                scenario.name
            )
            if scenario.mode == "insufficient" {
                XCTAssertEqual(
                    assessment.records.map(\.state),
                    [.insufficientEvidence, .insufficientEvidence, .insufficientEvidence, .insufficientEvidence],
                    scenario.name
                )
                XCTAssertTrue(assessment.records.flatMap(\.findings).allSatisfy { $0.affectedRegion == nil })
                let acknowledgement = try RoomQualitySaveAnywayAcknowledgementRequest.make(
                    for: assessment,
                    acknowledgedAt: fixtureDate
                )
                XCTAssertEqual(acknowledgement.acknowledgedFindingIDs.count, 4)
            }
        }
    }

    func testInvalidFixtureMatrixFailsClosedAtEachQualityBoundary() throws {
        let matrix = try loadFixtureMatrix()
        XCTAssertEqual(matrix.invalidScenarios.count, 8)

        var nonFinite = aggregationInput(mode: "good")
        nonFinite.frames[0].rawSharpness = .infinity
        XCTAssertThrowsError(try RoomQualityAggregator.aggregate(nonFinite))

        var degenerate = aggregationInput(mode: "good")
        degenerate.regions[0].dimensionsMeters.width = 0
        XCTAssertThrowsError(try RoomQualityAggregator.aggregate(degenerate))

        var singular = aggregationInput(mode: "good")
        singular.regions[0].roomTransform = .init(columnMajorValues: [
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 1,
        ])
        XCTAssertThrowsError(try RoomQualityAggregator.aggregate(singular))

        var inconsistent = makeAssessment(
            sharpness: .advisory,
            coverage: .acceptable,
            tracking: .acceptable,
            semantic: .acceptable
        )
        inconsistent.records[0].findings[0].reasonCode = .uncoveredRegion
        XCTAssertThrowsError(try inconsistent.validate())

        let report = try boundWeakReport()
        var rebound = report
        rebound.coordinateSpaceEpochID = "epoch-rebound"
        XCTAssertThrowsError(try rebound.validate())

        let canonical = try RoomRedesignCanonicalJSON.encode(report)
        var unknownObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        unknownObject["unexpectedQualityMember"] = true
        let unknownBytes = try JSONSerialization.data(withJSONObject: unknownObject, options: [.sortedKeys])
        XCTAssertThrowsError(try RoomQualityReportDecoder.decodeCanonical(unknownBytes))

        var badReasonObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        var reasonRecords = try XCTUnwrap(badReasonObject["records"] as? [[String: Any]])
        var reasonFindings = try XCTUnwrap(reasonRecords[0]["findings"] as? [[String: Any]])
        reasonFindings[0]["reasonCode"] = "madeUpReason"
        reasonRecords[0]["findings"] = reasonFindings
        badReasonObject["records"] = reasonRecords
        XCTAssertThrowsError(
            try RoomJSONCoding.makeDecoder().decode(
                RoomQualityReport.self,
                from: JSONSerialization.data(withJSONObject: badReasonObject, options: [.sortedKeys])
            )
        )

        var badDispositionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        var dispositionRecords = try XCTUnwrap(badDispositionObject["records"] as? [[String: Any]])
        var dispositionFindings = try XCTUnwrap(dispositionRecords[0]["findings"] as? [[String: Any]])
        dispositionFindings[0]["disposition"] = "hardFailure"
        dispositionRecords[0]["findings"] = dispositionFindings
        badDispositionObject["records"] = dispositionRecords
        XCTAssertThrowsError(
            try RoomJSONCoding.makeDecoder().decode(
                RoomQualityReport.self,
                from: JSONSerialization.data(withJSONObject: badDispositionObject, options: [.sortedKeys])
            )
        )
    }

    func testFutureCarrierKeepsCanonicalQualityReportUnchanged() throws {
        let report = try boundWeakReport()
        let source = RoomRedesignSourceRevision(
            projectID: report.projectID,
            revisionID: report.revisionID,
            coordinateSpaceEpochID: report.coordinateSpaceEpochID,
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
        let reportBytes = try RoomRedesignCanonicalJSON.encode(report)
        let carrier = RoomQualityReportCarrierV1(
            sourceRevision: source,
            qualityReport: report,
            qualityReportSHA256: RoomSHA256.hexDigest(of: reportBytes)
        )
        try carrier.validate()
        XCTAssertEqual(try RoomRedesignCanonicalJSON.encode(carrier.qualityReport), reportBytes)
    }

    func testCanonicalReportRoundTripsWithFourIndependentDimensions() throws {
        let assessment = makeAssessment(
            sharpness: .acceptable,
            coverage: .advisory,
            tracking: .acceptable,
            semantic: .acceptable
        )
        let acknowledgement = try RoomQualitySaveAnywayAcknowledgementRequest.make(
            for: assessment,
            acknowledgedAt: fixtureDate
        )
        let report = try assessment.bind(
            projectID: "project-001",
            revisionID: "revision-002",
            generatedAt: fixtureDate,
            acknowledgement: acknowledgement
        )

        try report.validate(
            expectedProjectID: "project-001",
            expectedRevisionID: "revision-002",
            expectedCoordinateSpaceEpochID: "epoch-001"
        )
        XCTAssertEqual(report.records.map(\.dimension), RoomQualityDimension.allCases)
        XCTAssertEqual(report.finishEligibility, .reviewRecommended)
        XCTAssertEqual(report.saveAcknowledgement?.acknowledgedFindingIDs, ["coverage-east-wall"])

        let bytes = try RoomRedesignCanonicalJSON.encode(report)
        let decoded = try RoomJSONCoding.makeDecoder().decode(RoomQualityReport.self, from: bytes)
        XCTAssertEqual(decoded, report)
        let digest = try RoomRedesignCanonicalJSON.sha256(report)
        XCTAssertEqual(digest, try RoomRedesignCanonicalJSON.sha256(decoded))
        XCTAssertEqual(digest, "f5757df1fc17596c3b3ab47fc63709a4bca2bafd3d5dc48f36990beedd63ab36")
    }

    func testWeakAssessmentRequiresExactSaveAnywayAcknowledgement() throws {
        let assessment = makeAssessment(
            sharpness: .acceptable,
            coverage: .advisory,
            tracking: .acceptable,
            semantic: .acceptable
        )

        XCTAssertEqual(RoomQualityFinishGate.eligibility(for: assessment), .reviewRecommended)
        XCTAssertThrowsError(
            try assessment.bind(
                projectID: "project-001",
                revisionID: "revision-002",
                generatedAt: fixtureDate,
                acknowledgement: nil
            )
        )

        var wrong = try RoomQualitySaveAnywayAcknowledgementRequest.make(
            for: assessment,
            acknowledgedAt: fixtureDate
        )
        wrong.acknowledgedFindingIDs = ["another-warning"]
        XCTAssertThrowsError(
            try assessment.bind(
                projectID: "project-001",
                revisionID: "revision-002",
                generatedAt: fixtureDate,
                acknowledgement: wrong
            )
        )
    }

    func testReportRejectsRevisionEpochReasonConfidenceAndRegionFailures() throws {
        let assessment = makeAssessment(
            sharpness: .advisory,
            coverage: .acceptable,
            tracking: .acceptable,
            semantic: .acceptable
        )
        let acknowledgement = try RoomQualitySaveAnywayAcknowledgementRequest.make(
            for: assessment,
            acknowledgedAt: fixtureDate
        )
        let report = try assessment.bind(
            projectID: "project-001",
            revisionID: "revision-002",
            generatedAt: fixtureDate,
            acknowledgement: acknowledgement
        )

        XCTAssertThrowsError(
            try report.validate(
                expectedProjectID: "project-001",
                expectedRevisionID: "revision-rebound",
                expectedCoordinateSpaceEpochID: "epoch-001"
            )
        )

        var rebound = report
        rebound.records[0].findings[0].coordinateSpaceEpochID = "epoch-rebound"
        XCTAssertThrowsError(try rebound.validate())

        var invalidConfidence = report
        invalidConfidence.records[0].findings[0].confidence = .infinity
        XCTAssertThrowsError(try invalidConfidence.validate())

        var inconsistentReason = report
        inconsistentReason.records[0].findings[0].reasonCode = .uncoveredRegion
        XCTAssertThrowsError(try inconsistentReason.validate())

        var singularRegion = report
        singularRegion.records[0].findings[0].affectedRegion?.roomTransform = RoomTransform4x4(
            columnMajorValues: [
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 1,
            ]
        )
        XCTAssertThrowsError(try singularRegion.validate())

        var degenerateRegion = report
        degenerateRegion.records[0].findings[0].affectedRegion?.dimensionsMeters.width = 0
        XCTAssertThrowsError(try degenerateRegion.validate())
    }

    func testAggregatorKeepsCombinedWarningsIndependentAndDoesNotInventRegions() throws {
        let east = try makeRegion(id: "east-wall", x: 2)
        let west = try makeRegion(id: "west-wall", x: -2)
        let frames = [
            frame("frame-001", sharpness: 12, regions: ["west-wall"]),
            frame("frame-002", sharpness: 1, regions: ["east-wall"]),
            frame("frame-003", sharpness: 10, regions: ["west-wall"]),
        ]
        let input = RoomQualityAggregationInput(
            coordinateSpaceEpochID: "epoch-001",
            regions: [east, west],
            frames: frames,
            tracking: [
                RoomQualityTrackingEvidence(
                    evidence: evidence("tracking-001", kind: .trackingObservation),
                    quality: .limited,
                    limitedReason: .excessiveMotion,
                    affectedRegionID: "east-wall"
                )
            ],
            semantics: [
                RoomQualitySemanticEvidence(
                    evidence: evidence("semantic-001", kind: .semanticElement),
                    classificationConfidence: .low,
                    affectedRegionID: "west-wall"
                )
            ]
        )

        let assessment = try RoomQualityAggregator.aggregate(input)
        XCTAssertEqual(
            assessment.advisoryFindings.map(\.dimension),
            [.visualSharpness, .spatialVisualCoverage, .arTracking, .semanticIdentificationConfidence]
        )
        XCTAssertEqual(
            Set(assessment.advisoryFindings.compactMap { $0.affectedRegion?.regionID }),
            Set(["east-wall", "west-wall"])
        )

        let insufficient = try RoomQualityAggregator.aggregate(
            RoomQualityAggregationInput(
                coordinateSpaceEpochID: "epoch-001",
                regions: [],
                frames: [],
                tracking: [],
                semantics: []
            )
        )
        XCTAssertEqual(insufficient.records.map(\.state), [
            .insufficientEvidence,
            .insufficientEvidence,
            .insufficientEvidence,
            .insufficientEvidence,
        ])
        XCTAssertTrue(insufficient.advisoryFindings.isEmpty)
        XCTAssertTrue(insufficient.records.flatMap(\.findings).allSatisfy { $0.affectedRegion == nil })
    }

    func testLiveCoachingThrottleIsBoundedDeduplicatedAndDeterministic() throws {
        let east = try makeRegion(id: "east-wall", x: 2)
        let cue = RoomQualityCoachingCue(
            dimension: .visualSharpness,
            reasonCode: .blurredRegion,
            affectedRegion: east,
            disposition: .revisitRecommended
        )
        var throttle = RoomQualityCoachingThrottle(minimumSequenceInterval: 3, maximumVisibleCues: 4)

        XCTAssertEqual(throttle.update(candidates: [cue, cue], sequence: 1), [cue])
        XCTAssertNil(throttle.update(candidates: [cue], sequence: 2))
        XCTAssertNil(throttle.update(candidates: [cue], sequence: 4))
        XCTAssertEqual(throttle.update(candidates: [], sequence: 5), [])
        XCTAssertNil(throttle.update(candidates: [], sequence: 6))
    }

    func testInitialCommitBindsQualityOnlyToNewImmutableRevisionAndDiscardPublishesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomQualityStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: fixtureDate),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-002"]
            )
        )
        let assessment = makeAssessment(
            sharpness: .acceptable,
            coverage: .advisory,
            tracking: .acceptable,
            semantic: .acceptable
        )
        let acknowledgement = try RoomQualitySaveAnywayAcknowledgementRequest.make(
            for: assessment,
            acknowledgedAt: fixtureDate
        )
        let commit = RoomInitialCaptureCommit(
            draft: makeDraft(),
            qualityAssessment: assessment,
            qualityAcknowledgement: acknowledgement
        )

        let discarded = try await store.commitInitialCapture(commit, decision: .discard)
        XCTAssertNil(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let savedResult = try await store.commitInitialCapture(commit, decision: .save)
        let saved = try XCTUnwrap(savedResult)
        XCTAssertEqual(saved.projectID, "project-001")
        XCTAssertEqual(saved.headRevisionID, "revision-002")
        let package = try await store.load(projectID: saved.projectID)
        let report = try XCTUnwrap(package.revisions.first?.manifest.qualityReport)
        try report.validate(
            expectedProjectID: "project-001",
            expectedRevisionID: "revision-002",
            expectedCoordinateSpaceEpochID: "epoch-001"
        )
        XCTAssertEqual(report.saveAcknowledgement?.acknowledgedFindingIDs, ["coverage-east-wall"])

        let revisionURL = root.appendingPathComponent(
            "project-001/revisions/revision-002/revision.json"
        )
        let originalBytes = try Data(contentsOf: revisionURL)
        _ = try await store.load(projectID: saved.projectID)
        XCTAssertEqual(try Data(contentsOf: revisionURL), originalBytes)
    }

    func testLegacyRevisionManifestWithoutQualityStillDecodesAndDoesNotReencodeQuality() throws {
        let legacyBytes = Data(
            #"{"createdAt":"2024-01-01T00:00:00Z","evidenceCompatibility":"strict","immutable":true,"projectID":"project-001","reason":"initial","revisionID":"revision-001"}"#.utf8
        )
        let manifest = try RoomJSONCoding.makeDecoder().decode(
            RoomRevisionManifest.self,
            from: legacyBytes
        )
        XCTAssertNil(manifest.qualityReport)
        let reencoded = try RoomJSONCoding.makeEncoder().encode(manifest)
        XCTAssertFalse(String(decoding: reencoded, as: UTF8.self).contains("qualityReport"))
    }

    private func makeAssessment(
        sharpness: RoomQualityDimensionState,
        coverage: RoomQualityDimensionState,
        tracking: RoomQualityDimensionState,
        semantic: RoomQualityDimensionState
    ) -> RoomQualityAssessment {
        let states: [(RoomQualityDimension, RoomQualityDimensionState)] = [
            (.visualSharpness, sharpness),
            (.spatialVisualCoverage, coverage),
            (.arTracking, tracking),
            (.semanticIdentificationConfidence, semantic),
        ]
        return RoomQualityAssessment(
            coordinateSpaceEpochID: "epoch-001",
            records: states.map { dimension, state in
                let reason: RoomQualityReasonCode
                switch (dimension, state) {
                case (.visualSharpness, .acceptable): reason = .sharpnessAcceptable
                case (.visualSharpness, .advisory): reason = .blurredRegion
                case (.spatialVisualCoverage, .acceptable): reason = .coverageAcceptable
                case (.spatialVisualCoverage, .advisory): reason = .uncoveredRegion
                case (.arTracking, .acceptable): reason = .trackingNormal
                case (.arTracking, .advisory): reason = .trackingLimited
                case (.semanticIdentificationConfidence, .acceptable): reason = .semanticConfidenceAcceptable
                case (.semanticIdentificationConfidence, .advisory): reason = .semanticLowConfidence
                case (_, .unavailable): reason = .sourceUnavailable
                case (_, .insufficientEvidence): reason = .insufficientEvidence
                }
                let findings: [RoomQualityFindingCandidate]
                if state == .advisory {
                    findings = [RoomQualityFindingCandidate(
                        findingID: dimension == .spatialVisualCoverage
                            ? "coverage-east-wall"
                            : "sharpness-east-wall",
                        dimension: dimension,
                        reasonCode: reason,
                        evidenceReferences: [evidence("evidence-001", kind: .captureSummary)],
                        affectedRegion: try? makeRegion(id: "east-wall", x: 2),
                        confidence: 0.8,
                        disposition: .revisitRecommended
                    )]
                } else {
                    findings = []
                }
                return RoomQualityAssessmentRecord(
                    dimension: dimension,
                    state: state,
                    reasonCode: reason,
                    findings: findings
                )
            }
        )
    }

    private func boundWeakReport() throws -> RoomQualityReport {
        let assessment = makeAssessment(
            sharpness: .advisory,
            coverage: .acceptable,
            tracking: .acceptable,
            semantic: .acceptable
        )
        return try assessment.bind(
            projectID: "project-001",
            revisionID: "revision-002",
            generatedAt: fixtureDate,
            acknowledgement: RoomQualitySaveAnywayAcknowledgementRequest.make(
                for: assessment,
                acknowledgedAt: fixtureDate
            )
        )
    }

    private func aggregationInput(mode: String) -> RoomQualityAggregationInput {
        if mode == "insufficient" {
            return .init(
                coordinateSpaceEpochID: "epoch-001",
                regions: [],
                frames: [],
                tracking: [],
                semantics: []
            )
        }
        let east = try! makeRegion(id: "east-wall", x: 2)
        let west = try! makeRegion(id: "west-wall", x: -2)
        let north = try! makeRegion(id: "north-wall", x: 0)
        let frames: [RoomQualityFrameEvidence]
        switch mode {
        case "blurred":
            frames = [
                frame("frame-001", sharpness: 1, regions: ["east-wall"]),
                frame("frame-002", sharpness: 10, regions: ["west-wall", "north-wall"]),
                frame("frame-003", sharpness: 10, regions: ["east-wall", "west-wall", "north-wall"]),
            ]
        case "uncovered":
            frames = [
                frame("frame-001", sharpness: 10, regions: ["west-wall", "north-wall"]),
                frame("frame-002", sharpness: 11, regions: ["west-wall", "north-wall"]),
                frame("frame-003", sharpness: 9, regions: ["west-wall", "north-wall"]),
            ]
        case "combined":
            frames = [
                frame("frame-001", sharpness: 1, regions: ["north-wall"]),
                frame("frame-002", sharpness: 10, regions: ["west-wall", "north-wall"]),
                frame("frame-003", sharpness: 10, regions: ["west-wall", "north-wall"]),
            ]
        default:
            frames = [
                frame("frame-001", sharpness: 10, regions: ["east-wall", "north-wall"]),
                frame("frame-002", sharpness: 11, regions: ["west-wall", "north-wall"]),
                frame("frame-003", sharpness: 9, regions: ["east-wall", "west-wall"]),
            ]
        }
        let tracking: [RoomQualityTrackingEvidence] = [
            .init(
                evidence: evidence("tracking-001", kind: .trackingObservation),
                quality: mode == "trackingLimited" || mode == "combined" ? .limited : .normal,
                limitedReason: mode == "trackingLimited" || mode == "combined" ? .excessiveMotion : nil,
                affectedRegionID: mode == "trackingLimited" || mode == "combined" ? "north-wall" : nil
            ),
        ]
        let semantics = [east, west, north].map { region in
            RoomQualitySemanticEvidence(
                evidence: evidence("semantic-\(region.regionID)", kind: .semanticElement),
                classificationConfidence: (mode == "semanticLow" || mode == "combined") && region.regionID == "west-wall"
                    ? .low
                    : .high,
                affectedRegionID: region.regionID
            )
        }
        return .init(
            coordinateSpaceEpochID: "epoch-001",
            regions: [east, west, north],
            frames: frames,
            tracking: tracking,
            semantics: semantics
        )
    }

    private func loadFixtureMatrix() throws -> QualityFixtureMatrix {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Quality/quality-fixture-matrix.json")
        return try JSONDecoder().decode(QualityFixtureMatrix.self, from: Data(contentsOf: url))
    }

    private func makeRegion(id: String, x: Double) throws -> RoomQualityRegion {
        try RoomQualityRegion(
            regionID: id,
            label: id.replacingOccurrences(of: "-", with: " ").capitalized,
            semanticElementID: id,
            dimensionsMeters: RoomDimensions(width: 1.5, height: 2.5, depth: 0.08),
            roomTransform: RoomTransform4x4(columnMajorValues: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                x, 1.25, 0, 1,
            ])
        )
    }

    private func evidence(
        _ id: String,
        kind: RoomQualityEvidenceKind
    ) -> RoomQualityEvidenceReference {
        RoomQualityEvidenceReference(
            evidenceID: id,
            kind: kind,
            sourceReference: id
        )
    }

    private func frame(
        _ id: String,
        sharpness: Double,
        regions: [String]
    ) -> RoomQualityFrameEvidence {
        RoomQualityFrameEvidence(
            evidence: evidence(id, kind: .posedKeyframe),
            rawSharpness: sharpness,
            visibleRegionIDs: regions
        )
    }

    private func makeDraft() -> RoomDraft {
        RoomDraft(
            metadata: RoomMetadata(
                projectID: "draft-project",
                customName: "Quality fixture",
                captureDate: fixtureDate,
                lastRevisedDate: fixtureDate,
                manualLocation: "Fixture lab",
                optionalGPS: nil,
                notes: "Deterministic quality fixture.",
                tags: ["quality"],
                thumbnailRelativePath: nil,
                archived: false
            ),
            revision: RoomRevisionPayload(
                semanticSnapshot: RoomSemanticSnapshot(
                    projectID: "draft-project",
                    revisionID: "draft-revision",
                    units: "meters",
                    accuracyDisclaimer: "Measurements are estimates, not survey-grade evidence.",
                    structuralElements: [
                        RoomSemanticElement(
                            id: "east-wall",
                            kind: "wall",
                            label: "East wall",
                            dimensionsMeters: RoomDimensions(width: 3, height: 2.5, depth: 0.08)
                        ),
                    ],
                    movableElements: []
                ),
                annotations: [],
                measurements: [],
                photos: []
            )
        )
    }

    private let fixtureDate = Date(timeIntervalSince1970: 1_704_067_200)
}

private struct QualityFixtureMatrix: Decodable {
    struct ValidScenario: Decodable {
        var name: String
        var mode: String
        var expectedAdvisoryDimensions: [RoomQualityDimension]
    }

    struct InvalidScenario: Decodable {
        var name: String
        var mutation: String
    }

    var validScenarios: [ValidScenario]
    var invalidScenarios: [InvalidScenario]
}
