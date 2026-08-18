import Foundation
import XCTest
@testable import RoomScanCore

final class RoomAIRoomPackageTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_786_896_000)

    func testArtifactPlansUseStableRepeatedSlotsCanonicalOrderAndExactDigests() throws {
        let source = sourceRevision()
        let context = try readyContext(source: source)
        let inventory = RoomAIArtifactInventory(
            referenceImageIDs: ["frame-c", "frame-a", "frame-b"],
            meshIDs: ["primary"],
            textureIDs: ["albedo"]
        )

        let aiReady = try RoomAIArtifactPlanner.makePlan(
            profile: .aiReady,
            context: context,
            inventory: inventory
        )
        let complete = try RoomAIArtifactPlanner.makePlan(
            profile: .complete,
            context: context,
            inventory: inventory
        )

        XCTAssertEqual(aiReady.slots, RoomAIArtifactSlot.canonicalized(aiReady.slots))
        XCTAssertEqual(
            aiReady.slots.filter { $0.artifactClass == .canonicalView }.count,
            6
        )
        XCTAssertEqual(
            aiReady.slots.filter { $0.artifactClass == .providerInstructions }.count,
            4
        )
        XCTAssertEqual(
            aiReady.slots.filter { $0.artifactClass == .selectedReferenceImage }.count,
            3
        )
        XCTAssertTrue(complete.isExplicitSuperset(of: aiReady))
        XCTAssertTrue(complete.slots.contains { $0.artifactClass == .rawRGB })
        XCTAssertFalse(aiReady.slots.contains { $0.artifactClass.isAIRawEvidence })

        var renamed = aiReady.slots
        let viewIndex = try XCTUnwrap(renamed.firstIndex { $0.artifactClass == .canonicalView })
        renamed[viewIndex].artifactID += "-renamed"
        let renamedDigest = try RoomRedesignContractDigests.aiArtifactPlanSHA256(
            sourceRevision: source,
            profile: .aiReady,
            slots: RoomAIArtifactSlot.canonicalized(renamed)
        )
        XCTAssertNotEqual(renamedDigest, aiReady.artifactPlanSHA256)

        var rebound = source
        rebound.semanticSHA256 = String(repeating: "9", count: 64)
        XCTAssertNotEqual(
            try RoomRedesignContractDigests.aiArtifactPlanSHA256(
                sourceRevision: rebound,
                profile: .aiReady,
                slots: aiReady.slots
            ),
            aiReady.artifactPlanSHA256
        )
    }

    func testAIProfileStructureRejectsRawWorldMapAndNonSupersetCompletePlans() throws {
        let source = sourceRevision()
        let context = try readyContext(source: source)
        XCTAssertThrowsError(
            try RoomAIArtifactPlanner.makePlan(
                profile: .aiReady,
                context: context,
                inventory: RoomAIArtifactInventory(rawRGBIDs: ["raw-frame"])
            )
        )

        let aiReady = try RoomAIArtifactPlanner.makePlan(
            profile: .aiReady,
            context: context,
            inventory: .init()
        )
        XCTAssertThrowsError(
            try RoomAIArtifactPlan.make(
                sourceRevision: source,
                profile: .aiReady,
                slots: aiReady.slots + [
                    RoomAIArtifactSlot(
                        artifactID: "world-map",
                        artifactClass: .worldMap
                    )
                ]
            )
        )
        XCTAssertFalse(RoomRedesignArtifactClass.allCases.map(\.rawValue).contains("preciseGPS"))

        let differentAIReady = try RoomAIArtifactPlanner.makePlan(
            profile: .aiReady,
            context: context,
            inventory: .init(meshIDs: ["different"])
        )
        let complete = try RoomAIArtifactPlanner.makePlan(
            profile: .complete,
            context: context,
            inventory: .init(meshIDs: ["primary"])
        )
        XCTAssertFalse(complete.isExplicitSuperset(of: differentAIReady))
    }

    func testReadinessRequiresExactSourceConfirmedOrientationAndValidIntent() throws {
        let source = sourceRevision()
        let companion = try companion(source: source)
        XCTAssertNoThrow(
            try RoomAIRoomPackageReadiness.requireEligible(
                sourceRevision: source,
                companion: companion
            )
        )

        var rebound = source
        rebound.revisionManifestSHA256 = String(repeating: "a", count: 64)
        XCTAssertThrowsError(
            try RoomAIRoomPackageReadiness.requireEligible(
                sourceRevision: rebound,
                companion: companion
            )
        )

        var suggested = companion
        suggested.orientation.source = .suggested
        XCTAssertThrowsError(
            try RoomAIRoomPackageReadiness.requireEligible(
                sourceRevision: source,
                companion: suggested
            )
        )

        var noIntent = companion
        noIntent.redesignIntent = nil
        XCTAssertThrowsError(
            try RoomAIRoomPackageReadiness.requireEligible(
                sourceRevision: source,
                companion: noIntent
            )
        )
    }

    func testReferenceSelectionIsBoundedSharpAndDeterministic() throws {
        let source = sourceRevision()
        let candidates = [
            candidate("frame-z", sharpness: 10, second: 3, source: source),
            candidate("frame-b", sharpness: 10, second: 2, source: source),
            candidate("frame-a", sharpness: 10, second: 2, source: source),
            candidate("frame-c", sharpness: 9, second: 1, source: source),
            candidate("frame-d", sharpness: 8, second: 0, source: source),
            candidate("legacy-frame", sharpness: 100, second: 0, source: nil),
        ]

        let first = try RoomAIReferenceImageSelector.select(
            candidates: candidates,
            sourceRevision: source,
            profile: .aiReady
        )
        let second = try RoomAIReferenceImageSelector.select(
            candidates: Array(candidates.reversed()),
            sourceRevision: source,
            profile: .aiReady
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selected.map(\.evidenceID), ["frame-a", "frame-b", "frame-z", "frame-c"])
        XCTAssertEqual(first.skipped.map(\.evidenceID), ["frame-d"])
        XCTAssertEqual(first.unavailable.map(\.evidenceID), ["legacy-frame"])

        var rebound = source
        rebound.coordinateSpaceEpochID = "epoch-999"
        XCTAssertThrowsError(
            try RoomAIReferenceImageSelector.select(
                candidates: [candidate("rebound", sharpness: 1, second: 0, source: rebound)],
                sourceRevision: source,
                profile: .aiReady
            )
        )
        XCTAssertThrowsError(
            try RoomAIReferenceImageSelector.select(
                candidates: [candidate("nonfinite", sharpness: .infinity, second: 0, source: source)],
                sourceRevision: source,
                profile: .aiReady
            )
        )
    }

    func testQualityCarrierAndProviderInstructionsRetainInvariantTruth() throws {
        let source = sourceRevision()
        let context = try readyContext(source: source)
        let plan = try RoomAIArtifactPlanner.makePlan(
            profile: .aiReady,
            context: context,
            inventory: .init(referenceImageIDs: ["frame-a"])
        )
        let carrier = try qualityCarrier(source: source)
        let carrierBytes = try RoomAIRoomPackageBuilder.validatedQualityCarrierBytes(
            carrier,
            boundTo: source
        )
        XCTAssertEqual(
            try RoomJSONCoding.makeDecoder().decode(
                RoomQualityReportCarrierV1.self,
                from: carrierBytes
            ),
            carrier
        )

        var reboundCarrier = carrier
        reboundCarrier.sourceRevision.semanticSHA256 = String(repeating: "8", count: 64)
        XCTAssertThrowsError(
            try RoomAIRoomPackageBuilder.validatedQualityCarrierBytes(
                reboundCarrier,
                boundTo: source
            )
        )

        let first = try RoomAIRoomPackageBuilder.makeProviderInstructions(
            context: context,
            plan: plan,
            selectedReferenceImageIDs: ["frame-a"],
            qualityCarrier: carrier
        )
        let second = try RoomAIRoomPackageBuilder.makeProviderInstructions(
            context: context,
            plan: plan,
            selectedReferenceImageIDs: ["frame-a"],
            qualityCarrier: carrier
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.files.map(\.provider), [.neutral, .chatGPT, .claude, .grok])
        XCTAssertEqual(Set(first.files.map(\.truthSHA256)), [first.truthSHA256])
        XCTAssertEqual(
            Set(first.files.map(\.data).map { RoomSHA256.hexDigest(of: $0) }).count,
            4
        )
        for file in first.files {
            let text = String(decoding: file.data, as: UTF8.self)
            XCTAssertTrue(text.contains("Truth digest: \(first.truthSHA256)"))
            XCTAssertTrue(text.contains("may not follow every instruction"))
            XCTAssertTrue(text.contains("Renovate and Reimagine output is conceptual"))
        }

        var changedCompanion = try companion(source: source)
        changedCompanion.redesignIntent?.request = "A different exact request"
        let changedContext = try RoomAIRoomPackageReadiness.requireEligible(
            sourceRevision: source,
            companion: changedCompanion
        )
        let changed = try RoomAIRoomPackageBuilder.makeProviderInstructions(
            context: changedContext,
            plan: plan,
            selectedReferenceImageIDs: ["frame-a"],
            qualityCarrier: carrier
        )
        XCTAssertNotEqual(changed.truthSHA256, first.truthSHA256)
    }

    func testBuilderRequiresExactFullLedgerAndExactRawApproval() async throws {
        let root = temporaryDirectory("RoomAIPackageBuilder")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = sourceRevision()
        let context = try readyContext(source: source)
        let plan = try RoomAIArtifactPlanner.makePlan(
            profile: .complete,
            context: context,
            inventory: .init(rawRGBIDs: ["frame-raw"])
        )
        let inputs = try buildInputs(
            for: plan,
            sourceDirectory: root.appendingPathComponent("sources"),
            includeRawRGB: true
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await RoomAIRoomPackageBuilder.prepare(
                packageID: "package-missing-ledger",
                plan: plan,
                inputs: Array(inputs.dropLast())
            )
        }

        let preparation = try await RoomAIRoomPackageBuilder.prepare(
            packageID: "package-complete",
            plan: plan,
            inputs: inputs
        )
        XCTAssertEqual(preparation.artifacts.map(\.slot), plan.slots)
        XCTAssertEqual(preparation.artifactPlanSHA256, plan.artifactPlanSHA256)
        XCTAssertEqual(
            preparation.selectionSHA256,
            try RoomRedesignContractDigests.aiSelectionSHA256(artifacts: preparation.artifacts)
        )

        XCTAssertThrowsError(
            try preparation.finalize(
                disclosureReview: disclosureReview(
                    for: preparation,
                    rawEvidenceDisclosureAccepted: false
                )
            )
        )
        let package = try preparation.finalize(
            disclosureReview: disclosureReview(
                for: preparation,
                rawEvidenceDisclosureAccepted: true
            )
        )
        XCTAssertEqual(package.artifactPlan, plan.slots)
        XCTAssertNoThrow(try package.validate())

        var missingLedger = package
        missingLedger.artifacts.removeLast()
        missingLedger.selectionSHA256 = try RoomRedesignContractDigests.aiSelectionSHA256(
            artifacts: missingLedger.artifacts
        )
        missingLedger.disclosureReview.reviewedSelectionSHA256 = missingLedger.selectionSHA256
        XCTAssertThrowsError(try missingLedger.validate())
    }

    func testArchiveIsDeterministicCanonicalStrictAndDoesNotMutateSources() async throws {
        let root = temporaryDirectory("RoomAIPackageArchive")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = sourceRevision()
        let context = try readyContext(source: source)

        for profile in [RoomAIRoomPackageProfile.aiReady, .complete] {
            let inventory = profile == .complete
                ? RoomAIArtifactInventory(rawRGBIDs: ["frame-raw"])
                : RoomAIArtifactInventory()
            let plan = try RoomAIArtifactPlanner.makePlan(
                profile: profile,
                context: context,
                inventory: inventory
            )
            let sourceDirectory = root.appendingPathComponent("\(profile.rawValue)-sources")
            let inputs = try buildInputs(
                for: plan,
                sourceDirectory: sourceDirectory,
                includeRawRGB: profile == .complete
            )
            let sourceBytes = try snapshotFiles(at: sourceDirectory)
            let preparation = try await RoomAIRoomPackageBuilder.prepare(
                packageID: "package-\(profile.rawValue)",
                plan: plan,
                inputs: inputs
            )
            let review = disclosureReview(
                for: preparation,
                rawEvidenceDisclosureAccepted: profile == .complete
            )
            let firstWorkspace = root.appendingPathComponent("\(profile.rawValue)-workspace-one")
            let secondWorkspace = root.appendingPathComponent("\(profile.rawValue)-workspace-two")
            try FileManager.default.createDirectory(at: firstWorkspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
            let firstArchive = root.appendingPathComponent("\(profile.rawValue)-one.zip")
            let secondArchive = root.appendingPathComponent("\(profile.rawValue)-two.zip")

            let first = try await RoomAIRoomPackageArchive.build(
                preparation: preparation,
                disclosureReview: review,
                archiveURL: firstArchive,
                workspaceURL: firstWorkspace
            )
            let second = try await RoomAIRoomPackageArchive.build(
                preparation: preparation,
                disclosureReview: review,
                archiveURL: secondArchive,
                workspaceURL: secondWorkspace
            )

            let firstArchiveData = try Data(contentsOf: firstArchive)
            let secondArchiveData = try Data(contentsOf: secondArchive)
            XCTAssertEqual(firstArchiveData, secondArchiveData)
            XCTAssertEqual(first.receipt, second.receipt)
            XCTAssertEqual(first.receipt.archiveByteCount, UInt64(firstArchiveData.count))
            XCTAssertEqual(
                first.receipt.archiveSHA256,
                RoomSHA256.hexDigest(of: firstArchiveData)
            )
            XCTAssertEqual(first.manifestData, second.manifestData)
            XCTAssertEqual(first.manifestData, try RoomRedesignCanonicalJSON.encode(first.package))
            XCTAssertEqual(try snapshotFiles(at: sourceDirectory), sourceBytes)

            let extraction = root.appendingPathComponent("\(profile.rawValue)-extraction")
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
            let validation = try await RoomAIRoomPackageArchive.extractAndValidate(
                archiveURL: firstArchive,
                into: extraction,
                expectedSourceRevision: source,
                expectedProfile: profile
            )
            XCTAssertEqual(validation.package, first.package)
            XCTAssertEqual(validation.manifestData, first.manifestData)
            XCTAssertEqual(validation.entries.count, first.receipt.entries.count)
            for (extracted, written) in zip(validation.entries, first.receipt.entries) {
                XCTAssertEqual(extracted.entryPath, written.entryPath)
                XCTAssertEqual(extracted.byteCount, written.byteCount)
                XCTAssertEqual(extracted.crc32, written.crc32)
                XCTAssertEqual(extracted.sha256Hex, written.sha256Hex)
            }

            if profile == .aiReady {
                let manifestURL = extraction.appendingPathComponent(RoomAIRoomPackageArchive.manifestEntryPath)
                let object = try JSONSerialization.jsonObject(with: first.manifestData)
                let noncanonical = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                try noncanonical.write(to: manifestURL, options: .atomic)
                let noncanonicalArchive = root.appendingPathComponent("noncanonical.zip")
                _ = try await RoomDeterministicZIP.write(
                    inputs: try zipInputs(from: extraction),
                    to: noncanonicalArchive
                )
                let noncanonicalExtraction = root.appendingPathComponent("noncanonical-extraction")
                try FileManager.default.createDirectory(at: noncanonicalExtraction, withIntermediateDirectories: true)
                await XCTAssertThrowsErrorAsync {
                    _ = try await RoomAIRoomPackageArchive.extractAndValidate(
                        archiveURL: noncanonicalArchive,
                        into: noncanonicalExtraction
                    )
                }

                try first.manifestData.write(to: manifestURL, options: .atomic)
                let hiddenURL = extraction.appendingPathComponent("raw/hidden.bin")
                try FileManager.default.createDirectory(
                    at: hiddenURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("hidden raw bytes".utf8).write(to: hiddenURL)
                let hiddenArchive = root.appendingPathComponent("hidden.zip")
                _ = try await RoomDeterministicZIP.write(
                    inputs: try zipInputs(from: extraction),
                    to: hiddenArchive
                )
                let hiddenExtraction = root.appendingPathComponent("hidden-extraction")
                try FileManager.default.createDirectory(at: hiddenExtraction, withIntermediateDirectories: true)
                await XCTAssertThrowsErrorAsync {
                    _ = try await RoomAIRoomPackageArchive.extractAndValidate(
                        archiveURL: hiddenArchive,
                        into: hiddenExtraction
                    )
                }
            }
        }
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

    private func companion(
        source: RoomRedesignSourceRevision
    ) throws -> RoomLocalRedesignExtensionV2 {
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: RoomOrientationInput(
                source: .confirmed,
                confidence: 0.9,
                entryPositionMeters: .init(x: 0, y: 0, z: -2),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: .init(
                    minimum: .init(x: -2, y: 0, z: -2),
                    maximum: .init(x: 2, y: 2.5, z: 2)
                ),
                referenceWallFeatureID: "wall-001"
            )
        )
        return RoomLocalRedesignExtensionV2(
            sourceRevision: source,
            orientation: orientation,
            redesignIntent: RoomRedesignIntentV2(
                request: "Keep the windows and make this a calm reading room.",
                scope: .stage,
                constraints: .init(style: ["warm-minimal"]),
                permissions: [
                    .init(featureID: "window-001", permission: .preserve),
                    .init(featureID: "sofa-001", permission: .mayChange),
                ]
            ),
            propertyMembership: nil,
            conceptMetadata: []
        )
    }

    private func readyContext(
        source: RoomRedesignSourceRevision
    ) throws -> RoomAIRoomPackageReadyContext {
        try RoomAIRoomPackageReadiness.requireEligible(
            sourceRevision: source,
            companion: companion(source: source)
        )
    }

    private func candidate(
        _ evidenceID: String,
        sharpness: Double,
        second: TimeInterval,
        source: RoomRedesignSourceRevision?
    ) -> RoomAIReferenceImageCandidate {
        RoomAIReferenceImageCandidate(
            evidenceID: evidenceID,
            sourceRevision: source,
            capturedAt: fixedDate.addingTimeInterval(second),
            sharpness: sharpness
        )
    }

    private func qualityCarrier(
        source: RoomRedesignSourceRevision
    ) throws -> RoomQualityReportCarrierV1 {
        let records = RoomQualityDimension.allCases.map { dimension -> RoomQualityDimensionRecord in
            let reason: RoomQualityReasonCode
            switch dimension {
            case .visualSharpness: reason = .sharpnessAcceptable
            case .spatialVisualCoverage: reason = .coverageAcceptable
            case .arTracking: reason = .trackingNormal
            case .semanticIdentificationConfidence: reason = .semanticConfidenceAcceptable
            }
            return RoomQualityDimensionRecord(
                dimension: dimension,
                state: .acceptable,
                reasonCode: reason,
                findings: []
            )
        }
        let report = RoomQualityReport(
            projectID: source.projectID,
            revisionID: source.revisionID,
            coordinateSpaceEpochID: source.coordinateSpaceEpochID,
            generatedAt: fixedDate,
            records: records,
            finishEligibility: .proceedNormally,
            saveAcknowledgement: nil
        )
        let carrier = RoomQualityReportCarrierV1(
            sourceRevision: source,
            qualityReport: report,
            qualityReportSHA256: try RoomRedesignCanonicalJSON.sha256(report)
        )
        try carrier.validate()
        return carrier
    }

    private func buildInputs(
        for plan: RoomAIArtifactPlan,
        sourceDirectory: URL,
        includeRawRGB: Bool
    ) throws -> [RoomAIArtifactBuildInput] {
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        return try plan.slots.map { slot in
            let optionalClasses: Set<RoomRedesignArtifactClass> = [
                .selectedReferenceImage, .materials, .qualityReport, .mesh, .texture,
                .rawRGB, .rawDepth, .rawConfidence, .diagnostics,
            ]
            let shouldInclude = !optionalClasses.contains(slot.artifactClass)
                || (includeRawRGB && slot.artifactClass == .rawRGB && !slot.artifactID.hasSuffix("unavailable"))
            guard shouldInclude else {
                return .unavailable(slot: slot, reasonCode: "source-unavailable")
            }
            let sourceURL = sourceDirectory.appendingPathComponent("\(slot.artifactID).bytes")
            try Data("payload:\(slot.artifactClass.rawValue):\(slot.artifactID)".utf8).write(to: sourceURL)
            let pathAndType = artifactPathAndMediaType(for: slot)
            return .included(
                slot: slot,
                sourceURL: sourceURL,
                relativePath: pathAndType.path,
                mediaType: pathAndType.mediaType
            )
        }
    }

    private func artifactPathAndMediaType(
        for slot: RoomAIArtifactSlot
    ) -> (path: String, mediaType: String) {
        switch slot.artifactClass {
        case .normalizedSemantics: return ("truth/semantic-model.json", "application/json")
        case .revisionLineage: return ("truth/revision-lineage.json", "application/json")
        case .orientation: return ("truth/orientation.json", "application/json")
        case .floorPlan: return ("derivatives/floor-plan.png", "image/png")
        case .canonicalView: return ("derivatives/canonical-views/\(slot.artifactID).png", "image/png")
        case .selectedReferenceImage: return ("references/\(slot.artifactID).jpg", "image/jpeg")
        case .materials: return ("appearance/materials.json", "application/json")
        case .qualityReport: return ("quality/quality-report-carrier.json", "application/json")
        case .roomBrief: return ("brief/room-brief.txt", "text/plain")
        case .redesignIntent: return ("intent/redesign-intent.json", "application/json")
        case .providerInstructions:
            return ("instructions/\(slot.artifactID).txt", "text/plain")
        case .mesh: return ("geometry/\(slot.artifactID).usdz", "model/vnd.usdz+zip")
        case .texture: return ("appearance/textures/\(slot.artifactID).png", "image/png")
        case .rawRGB: return ("raw/\(slot.artifactID).jpg", "image/jpeg")
        case .rawDepth, .rawConfidence:
            return ("raw/\(slot.artifactID).bin", "application/octet-stream")
        case .diagnostics: return ("diagnostics/\(slot.artifactID).json", "application/json")
        case .conceptAttachment, .comments, .worldMap:
            return ("unsupported/\(slot.artifactID).bin", "application/octet-stream")
        }
    }

    private func disclosureReview(
        for preparation: RoomAIRoomPackagePreparation,
        rawEvidenceDisclosureAccepted: Bool
    ) -> RoomDisclosureReview {
        RoomDisclosureReview(
            reviewID: "review-001",
            reviewedAt: fixedDate,
            decision: .approved,
            sourceRevisionID: preparation.sourceRevision.revisionID,
            sourceRevisionManifestSHA256: preparation.sourceRevision.revisionManifestSHA256,
            reviewedArtifactPlanSHA256: preparation.artifactPlanSHA256,
            reviewedSelectionSHA256: preparation.selectionSHA256,
            preciseGPSExcluded: true,
            rawEvidenceDisclosureAccepted: rawEvidenceDisclosureAccepted
        )
    }

    private func snapshotFiles(at root: URL) throws -> [String: Data] {
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                guard let rootIndex = url.pathComponents.lastIndex(of: root.lastPathComponent) else {
                    throw RoomAIRoomPackageError.archiveClosureMismatch("test-relative-path")
                }
                let relative = url.pathComponents.dropFirst(rootIndex + 1).joined(separator: "/")
                result[relative] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func zipInputs(from root: URL) throws -> [RoomZIPInput] {
        try snapshotFiles(at: root).keys.sorted().map { relativePath in
            RoomZIPInput(
                sourceURL: root.appendingPathComponent(relativePath),
                entryPath: try RoomExportEntryPath(relativePath),
                mediaType: relativePath == RoomAIRoomPackageArchive.manifestEntryPath
                    ? "application/json"
                    : "application/octet-stream"
            )
        }
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw.", file: file, line: line)
    } catch {
        // Expected.
    }
}
