import Foundation
import XCTest
@testable import RoomScanCore

final class RoomSpatialTruthTests: XCTestCase {
    func testCanonicalOrientationAndCamerasAreDeterministicAndRoundTrip() throws {
        let source = sourceRevision()
        let bounds = RoomNormalizedBounds(
            minimum: RoomRedesignVector3(x: -2.7, y: 0, z: -2.1),
            maximum: RoomRedesignVector3(x: 2.7, y: 2.7, z: 2.1)
        )
        let input = RoomOrientationInput(
            source: .confirmed,
            confidence: 0.92,
            entryPositionMeters: RoomRedesignVector3(x: -1.4, y: 0, z: -2.0),
            inwardDirection: RoomRedesignVector3(x: 0, y: 0, z: 1),
            roomBounds: bounds,
            referenceWallFeatureID: "structure-wall-north-001"
        )

        let first = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: input
        )
        let second = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: input
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.canonicalCameras.map(\.role), [
            .entry, .wall, .corner, .orbit, .perspective, .topDown,
        ])
        XCTAssertEqual(first.topDownOrientation.upAxis, .positiveY)
        XCTAssertEqual(first.topDownOrientation.screenUp, first.canonicalAxes.forward)
        XCTAssertNoThrow(try first.validate(boundTo: source))

        let intent = try makeIntent()
        let extensionDocument = RoomLocalRedesignExtensionV2(
            sourceRevision: source,
            orientation: first,
            redesignIntent: intent,
            propertyMembership: nil,
            conceptMetadata: []
        )
        let encoded = try RoomRedesignCanonicalJSON.encode(extensionDocument)
        let document = try RoomRedesignContractValidator.validate(data: encoded)
        guard case let .localRedesignExtensionV2(decoded) = document else {
            return XCTFail("Expected a Slice 1 local redesign extension.")
        }
        XCTAssertEqual(decoded, extensionDocument)
        XCTAssertEqual(try RoomRedesignCanonicalJSON.encode(decoded), encoded)
        XCTAssertEqual(
            try RoomRedesignCanonicalJSON.sha256(decoded),
            try RoomRedesignCanonicalJSON.sha256(extensionDocument)
        )
    }

    func testCanonicalCameraGoldenFixtureIsStable() throws {
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: sourceRevision(),
            input: RoomOrientationInput(
                source: .manual,
                confidence: 1,
                entryPositionMeters: RoomRedesignVector3(x: -1.4, y: 0, z: -2),
                inwardDirection: RoomRedesignVector3(x: 0, y: 0, z: 1),
                roomBounds: RoomNormalizedBounds(
                    minimum: RoomRedesignVector3(x: -2.7, y: 0, z: -2.1),
                    maximum: RoomRedesignVector3(x: 2.7, y: 2.7, z: 2.1)
                ),
                referenceWallFeatureID: "structure-wall-north-001"
            )
        )

        XCTAssertEqual(
            try RoomRedesignCanonicalJSON.sha256(orientation),
            "46c43ee19fd7b9834c6f2656481c3af9012f9ad9a100f53bc5c5f331226ca6ef"
        )
    }

    func testTopDownPresentationTransformIsValidatedPersistentAndCannotChangeSpatialTruth() throws {
        let source = sourceRevision()
        let bounds = RoomNormalizedBounds(
            minimum: .init(x: -2.7, y: 0, z: -2.1),
            maximum: .init(x: 2.7, y: 2.7, z: 2.1)
        )
        let baseInput = RoomOrientationInput(
            source: .confirmed,
            confidence: 1,
            entryPositionMeters: .init(x: -1.4, y: 0, z: -2),
            inwardDirection: .init(x: 0, y: 0, z: 1),
            roomBounds: bounds,
            entryFeatureID: "door-001",
            referenceWallFeatureID: nil
        )
        let base = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: baseInput
        )
        var transformedInput = baseInput
        transformedInput.topDownPresentation = .init(
            quarterTurnsClockwise: 3,
            isMirroredHorizontally: true
        )
        let transformed = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: transformedInput
        )

        XCTAssertEqual(transformed.entryPositionMeters, base.entryPositionMeters)
        XCTAssertEqual(transformed.inwardDirection, base.inwardDirection)
        XCTAssertEqual(transformed.canonicalAxes, base.canonicalAxes)
        XCTAssertEqual(transformed.canonicalCameras, base.canonicalCameras)
        XCTAssertEqual(transformed.topDownOrientation.screenUp, base.topDownOrientation.screenUp)
        XCTAssertEqual(
            transformed.topDownOrientation.presentationTransform,
            .init(quarterTurnsClockwise: 3, isMirroredHorizontally: true)
        )
        let roundTrip = try JSONDecoder().decode(
            RoomOrientationContractV2.self,
            from: RoomRedesignCanonicalJSON.encode(transformed)
        )
        XCTAssertEqual(roundTrip, transformed)

        var controls = RoomTopDownPresentationTransform.viewerAligned
        for _ in 0..<4 { controls = controls.rotatedClockwise() }
        XCTAssertEqual(controls, .viewerAligned)
        XCTAssertEqual(controls.togglingHorizontalMirror().togglingHorizontalMirror(), controls)

        var invalid = transformed
        invalid.topDownOrientation.presentationTransform?.quarterTurnsClockwise = 4
        XCTAssertThrowsError(try invalid.validate(boundTo: source))
    }

    func testInvalidOrientationAxesCamerasAndBindingsFailClosed() throws {
        let source = sourceRevision()
        let bounds = RoomNormalizedBounds(
            minimum: RoomRedesignVector3(x: -2, y: 0, z: -2),
            maximum: RoomRedesignVector3(x: 2, y: 2.5, z: 2)
        )

        XCTAssertThrowsError(try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: RoomOrientationInput(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: 0, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 0),
                roomBounds: bounds,
                referenceWallFeatureID: nil
            )
        ))

        XCTAssertThrowsError(try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: RoomOrientationInput(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: .nan, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: bounds,
                referenceWallFeatureID: nil
            )
        ))

        XCTAssertThrowsError(try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: RoomOrientationInput(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: 0, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: .init(
                    minimum: .init(x: 1, y: 0, z: 1),
                    maximum: .init(x: 1, y: 2, z: 1)
                ),
                referenceWallFeatureID: nil
            )
        ))

        var orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: .init(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: 0, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: bounds,
                referenceWallFeatureID: nil
            )
        )
        orientation.coordinateSpaceEpochID = "epoch-rebound"
        XCTAssertThrowsError(try orientation.validate(boundTo: source))

        orientation.coordinateSpaceEpochID = source.coordinateSpaceEpochID
        orientation.canonicalAxes.forward = orientation.canonicalAxes.right
        XCTAssertThrowsError(try orientation.validate(boundTo: source))

        orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: .init(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: 0, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: bounds,
                referenceWallFeatureID: nil
            )
        )
        orientation.canonicalCameras[0].targetMeters = orientation.canonicalCameras[0].positionMeters
        XCTAssertThrowsError(try orientation.validate(boundTo: source))
    }

    func testOrientationSuggestionUsesAppOwnedEvidenceButNeverBecomesReady() throws {
        let scanStartPose = RoomScanStartPose(
            positionMeters: .init(x: -1.3, y: 1.55, z: -1.9),
            forwardDirection: .init(x: 0, y: 0, z: 1),
            coordinateSpaceEpochID: "epoch-001"
        )
        let suggestion = try RoomOrientationSuggestionEngine.suggest(
            scanStartPose: scanStartPose,
            candidates: [
                RoomEntryCandidate(
                    featureID: "door-001",
                    semanticRole: .door,
                    positionMeters: .init(x: -1.4, y: 1, z: -2),
                    inwardDirection: .init(x: 0, y: 0, z: 1),
                    confidence: 0.9
                ),
                RoomEntryCandidate(
                    featureID: "window-001",
                    semanticRole: .window,
                    positionMeters: .init(x: 2, y: 1, z: 0),
                    inwardDirection: .init(x: -1, y: 0, z: 0),
                    confidence: 1
                ),
            ]
        )

        XCTAssertEqual(suggestion?.source, .suggested)
        XCTAssertEqual(suggestion?.evidence.featureID, "door-001")
        XCTAssertEqual(suggestion?.evidence.scanStartPose, scanStartPose)
        XCTAssertEqual(suggestion?.coordinateSpaceEpochID, "epoch-001")

        let suggested = try XCTUnwrap(suggestion)
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: sourceRevision(),
            input: RoomOrientationInput(
                source: .suggested,
                confidence: suggested.confidence,
                entryPositionMeters: suggested.entryPositionMeters,
                inwardDirection: suggested.inwardDirection,
                roomBounds: .init(
                    minimum: .init(x: -2.7, y: 0, z: -2.1),
                    maximum: .init(x: 2.7, y: 2.7, z: 2.1)
                ),
                entryFeatureID: suggested.evidence.featureID,
                referenceWallFeatureID: nil,
                suggestionEvidence: suggested.evidence
            )
        )
        XCTAssertEqual(orientation.entryFeatureID, "door-001")
        let roundTrip = try JSONDecoder().decode(
            RoomOrientationContractV2.self,
            from: RoomRedesignCanonicalJSON.encode(orientation)
        )
        XCTAssertEqual(roundTrip.suggestionEvidence?.scanStartPose, scanStartPose)
        XCTAssertEqual(roundTrip.entryFeatureID, "door-001")

        let extensionDocument = try extensionDocument(source: .suggested)
        XCTAssertThrowsError(try RoomOrientationReadiness.requireEligible(
            extensionDocument,
            operation: .aiExport
        )) { error in
            XCTAssertEqual(error as? RoomOrientationReadinessError, .userConfirmationRequired)
        }
    }

    func testNewOrientationEvidenceRoundTripsWhileEarlierSliceOneBytesRemainDecodable() throws {
        let source = sourceRevision()
        let scanStartPose = RoomScanStartPose(
            positionMeters: .init(x: -1.3, y: 1.55, z: -1.9),
            forwardDirection: .init(x: 0, y: 0, z: 1),
            coordinateSpaceEpochID: source.coordinateSpaceEpochID
        )
        let suggestion = try XCTUnwrap(RoomOrientationSuggestionEngine.suggest(
            scanStartPose: scanStartPose,
            candidates: [
                .init(
                    featureID: "door-001",
                    semanticRole: .door,
                    positionMeters: .init(x: -1.4, y: 0, z: -2),
                    inwardDirection: .init(x: 0, y: 0, z: 1),
                    confidence: 0.9
                ),
            ]
        ))
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: .init(
                source: .suggested,
                confidence: suggestion.confidence,
                entryPositionMeters: suggestion.entryPositionMeters,
                inwardDirection: suggestion.inwardDirection,
                roomBounds: .init(
                    minimum: .init(x: -2.7, y: 0, z: -2.1),
                    maximum: .init(x: 2.7, y: 2.7, z: 2.1)
                ),
                entryFeatureID: suggestion.evidence.featureID,
                referenceWallFeatureID: nil,
                suggestionEvidence: suggestion.evidence
            )
        )
        let document = RoomLocalRedesignExtensionV2(
            sourceRevision: source,
            orientation: orientation,
            redesignIntent: nil,
            propertyMembership: nil,
            conceptMetadata: []
        )
        let currentBytes = try RoomRedesignCanonicalJSON.encode(document)
        guard case let .localRedesignExtensionV2(decodedCurrent) = try RoomRedesignContractValidator.validate(data: currentBytes) else {
            return XCTFail("Expected the current Slice 1 extension.")
        }
        XCTAssertEqual(decodedCurrent, document)
        XCTAssertEqual(
            try RoomRedesignCanonicalJSON.sha256(document),
            "3f15e19e967f30101429cb18ebbcde7147c04affadff104264aa0a04d14628e5"
        )

        var earlierObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentBytes) as? [String: Any]
        )
        var earlierOrientation = try XCTUnwrap(earlierObject["orientation"] as? [String: Any])
        earlierOrientation.removeValue(forKey: "entryFeatureID")
        var earlierEvidence = try XCTUnwrap(earlierOrientation["suggestionEvidence"] as? [String: Any])
        earlierEvidence.removeValue(forKey: "scanStartPose")
        earlierOrientation["suggestionEvidence"] = earlierEvidence
        earlierObject["orientation"] = earlierOrientation
        let earlierBytes = try JSONSerialization.data(withJSONObject: earlierObject, options: [.sortedKeys])
        guard case let .localRedesignExtensionV2(decodedEarlier) = try RoomRedesignContractValidator.validate(data: earlierBytes) else {
            return XCTFail("Expected earlier Slice 1 bytes to remain valid.")
        }
        XCTAssertNil(decodedEarlier.orientation.entryFeatureID)
        XCTAssertNil(decodedEarlier.orientation.suggestionEvidence?.scanStartPose)
    }

    func testEntryAndScanStartEvidenceCannotBeRebound() throws {
        let source = sourceRevision()
        let scanStartPose = RoomScanStartPose(
            positionMeters: .init(x: -1.3, y: 1.55, z: -1.9),
            forwardDirection: .init(x: 0, y: 0, z: 1),
            coordinateSpaceEpochID: source.coordinateSpaceEpochID
        )
        let suggestion = try XCTUnwrap(RoomOrientationSuggestionEngine.suggest(
            scanStartPose: scanStartPose,
            candidates: [
                .init(
                    featureID: "door-001",
                    semanticRole: .door,
                    positionMeters: .init(x: -1.4, y: 0, z: -2),
                    inwardDirection: .init(x: 0, y: 0, z: 1),
                    confidence: 0.9
                ),
            ]
        ))
        var orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: .init(
                source: .suggested,
                confidence: suggestion.confidence,
                entryPositionMeters: suggestion.entryPositionMeters,
                inwardDirection: suggestion.inwardDirection,
                roomBounds: .init(
                    minimum: .init(x: -2.7, y: 0, z: -2.1),
                    maximum: .init(x: 2.7, y: 2.7, z: 2.1)
                ),
                entryFeatureID: suggestion.evidence.featureID,
                referenceWallFeatureID: nil,
                suggestionEvidence: suggestion.evidence
            )
        )

        orientation.entryFeatureID = "door-rebound"
        XCTAssertThrowsError(try orientation.validate(boundTo: source))

        orientation.entryFeatureID = suggestion.evidence.featureID
        var evidence = try XCTUnwrap(orientation.suggestionEvidence)
        var reboundPose = try XCTUnwrap(evidence.scanStartPose)
        reboundPose.coordinateSpaceEpochID = "epoch-rebound"
        evidence.scanStartPose = reboundPose
        orientation.suggestionEvidence = evidence
        XCTAssertThrowsError(try orientation.validate(boundTo: source))

        orientation.source = .confirmed
        XCTAssertThrowsError(try orientation.validate(boundTo: source))
    }

    func testOrientationReadinessAcceptsConfirmedAndManualButRejectsRebinding() throws {
        XCTAssertNoThrow(try RoomOrientationReadiness.requireEligible(
            try extensionDocument(source: .confirmed),
            operation: .aiExport
        ))
        XCTAssertNoThrow(try RoomOrientationReadiness.requireEligible(
            try extensionDocument(source: .manual),
            operation: .publication
        ))

        var rebound = try extensionDocument(source: .confirmed)
        rebound.sourceRevision.revisionID = "revision-999"
        XCTAssertThrowsError(try RoomOrientationReadiness.requireEligible(
            rebound,
            expectedSourceRevision: sourceRevision(),
            operation: .publication
        ))
    }

    func testStructuredIntentPermissionsAndConceptsCannotCarryCapturedTruth() throws {
        let intent = try makeIntent()
        XCTAssertEqual(intent.request, "Stage the room with natural materials and preserve the shell.")
        XCTAssertEqual(intent.scope, .stage)
        XCTAssertEqual(intent.constraints?.accessibility, ["Keep a 36 inch clear route"])
        XCTAssertEqual(intent.permissions.map(\.permission), [.preserve, .mayChange, .requestedChange])

        let encodedIntent = try RoomRedesignCanonicalJSON.encode(intent)
        let intentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedIntent) as? [String: Any])
        XCTAssertNil(intentObject["geometry"])
        XCTAssertNil(intentObject["measurements"])
        XCTAssertNil(intentObject["evidence"])
        XCTAssertNil(intentObject["revisionHistory"])

        let concept = RoomConceptMetadataV2(
            conceptSetID: "concept-001",
            sourceRevision: sourceRevision(),
            request: intent.request,
            scope: intent.scope,
            provider: "User disclosed provider",
            sourceAIRoomPackageSchemaVersion: "roomscan-ai-room-package-v1",
            sourceAIRoomPackageID: "package-001",
            createdAt: Date(timeIntervalSince1970: 1_786_492_800),
            importedAt: Date(timeIntervalSince1970: 1_786_493_100),
            mappingStatus: .manual,
            attachments: [],
            comments: [],
            approvalState: .pending,
            archiveState: .active
        )
        XCTAssertNoThrow(try concept.validate(boundTo: sourceRevision()))
        let encodedConcept = try RoomRedesignCanonicalJSON.encode(concept)
        let conceptObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedConcept) as? [String: Any])
        XCTAssertNil(conceptObject["geometry"])
        XCTAssertNil(conceptObject["measurements"])
        XCTAssertNil(conceptObject["evidence"])
        XCTAssertNil(conceptObject["revisionHistory"])
    }

    func testPropertyContainerContainsIndependentRoomsOnly() throws {
        let property = RoomPropertyContainerV1(
            propertyID: "property-001",
            displayName: "Maple Street",
            roomProjectIDs: ["project-001", "project-002"],
            createdAt: Date(timeIntervalSince1970: 1_786_492_800),
            updatedAt: Date(timeIntervalSince1970: 1_786_492_800)
        )
        XCTAssertNoThrow(try property.validate())
        let encoded = try RoomRedesignCanonicalJSON.encode(property)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["transforms"])
        XCTAssertNil(object["alignment"])
        XCTAssertNil(object["doorwayConnectivity"])
        XCTAssertNil(object["topology"])
    }

    func testSemanticRolesCoverEveryRequiredCategoryWithNonColorIdentity() {
        let cases: [(RoomSemanticElement, RoomSemanticRole)] = [
            (element(kind: "wall", mobility: .structural), .wall),
            (element(kind: "door", mobility: .structural), .door),
            (element(kind: "window", mobility: .structural), .window),
            (element(kind: "opening", mobility: .structural), .opening),
            (element(kind: "floor", mobility: .structural), .floor),
            (element(kind: "ceiling", mobility: .structural), .ceiling),
            (element(kind: "sink", mobility: .fixed), .fixedObject),
            (element(kind: "chair", mobility: .movable), .movableObject),
            (element(kind: "mystery", mobility: .unknown), .unknownObject),
        ]

        for (element, expected) in cases {
            let token = RoomSemanticPresentation.token(for: element)
            XCTAssertEqual(token.role, expected)
            XCTAssertFalse(token.displayName.isEmpty)
            XCTAssertFalse(token.symbolName.isEmpty)
            XCTAssertFalse(token.materialPattern.rawValue.isEmpty)
            XCTAssertTrue(token.accessibilityDescription(for: element).contains(token.displayName))
        }
        XCTAssertEqual(Set(cases.map { RoomSemanticPresentation.token(for: $0.0).symbolName }).count, 9)
        XCTAssertEqual(Set(cases.map { RoomSemanticPresentation.token(for: $0.0).materialPattern }).count, 9)
    }

    private func extensionDocument(source: RoomOrientationSource) throws -> RoomLocalRedesignExtensionV2 {
        let sourceRevision = sourceRevision()
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: sourceRevision,
            input: RoomOrientationInput(
                source: source,
                confidence: source == .suggested ? 0.76 : 1,
                entryPositionMeters: .init(x: -1.4, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: .init(
                    minimum: .init(x: -2.7, y: 0, z: -2.1),
                    maximum: .init(x: 2.7, y: 2.7, z: 2.1)
                ),
                referenceWallFeatureID: source == .manual ? "wall-001" : nil
            )
        )
        return RoomLocalRedesignExtensionV2(
            sourceRevision: sourceRevision,
            orientation: orientation,
            redesignIntent: try makeIntent(),
            propertyMembership: nil,
            conceptMetadata: []
        )
    }

    private func sourceRevision() -> RoomRedesignSourceRevision {
        RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "1", count: 64),
            revisionManifestSHA256: String(repeating: "2", count: 64)
        )
    }

    private func makeIntent() throws -> RoomRedesignIntentV2 {
        let intent = RoomRedesignIntentV2(
            request: "Stage the room with natural materials and preserve the shell.",
            scope: .stage,
            constraints: RoomRedesignStructuredConstraints(
                purpose: ["Shared workspace"],
                style: ["Warm modern"],
                budget: "Under 20,000 USD",
                householdNeeds: ["Seating for four"],
                accessibility: ["Keep a 36 inch clear route"],
                circulation: ["Preserve entry path"],
                materials: ["Natural oak"],
                colors: ["Warm neutral"],
                referenceImageIDs: ["reference-001"],
                desiredObjects: ["Round table"]
            ),
            permissions: [
                .init(featureID: "wall-001", permission: .preserve),
                .init(featureID: "chair-001", permission: .mayChange),
                .init(featureID: "lighting-001", permission: .requestedChange),
            ]
        )
        try intent.validate()
        return intent
    }

    private func element(kind: String, mobility: RoomMobilityAssessment) -> RoomSemanticElement {
        RoomSemanticElement(
            id: "\(kind)-001",
            kind: kind,
            label: "Sample \(kind)",
            dimensionsMeters: .init(width: 1, height: 1, depth: 1),
            mobility: mobility
        )
    }
}
