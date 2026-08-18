import Foundation
import XCTest
@testable import RoomScanCore

final class RoomRedesignContractFixtureTests: XCTestCase {
    func testValidV1FixturesValidate() throws {
        let expectations: [(String, RoomRedesignContractKind)] = [
            ("valid-local-extension-v1.json", .localRedesignExtension),
            ("valid-hosted-resource-v1.json", .hostedAPIResource),
            ("valid-ai-ready-v1.json", .aiRoomPackage),
            ("valid-ai-complete-v1.json", .aiRoomPackage),
            ("valid-working-sync-v1.json", .workingProjectSync),
            ("valid-working-sync-raw-opt-in-v1.json", .workingProjectSync),
            ("valid-portal-snapshot-v1.json", .portalSnapshot)
        ]

        for (fixture, expectedKind) in expectations {
            let document = try validateFixture(named: fixture)
            XCTAssertEqual(document.kind, expectedKind, fixture)
        }
    }

    func testCanonicalFixtureDigestsMatchTheirPlansAndLedgers() throws {
        for fixture in ["valid-ai-ready-v1.json", "valid-ai-complete-v1.json"] {
            let package: RoomAIRoomPackage = try aiPackageFixture(named: fixture)
            XCTAssertEqual(
                package.artifactPlanSHA256,
                try RoomRedesignContractDigests.aiArtifactPlanSHA256(
                    sourceRevision: package.sourceRevision,
                    profile: package.profile
                ),
                fixture
            )
            XCTAssertEqual(
                package.selectionSHA256,
                try RoomRedesignContractDigests.aiSelectionSHA256(artifacts: package.artifacts),
                fixture
            )
        }

        for fixture in ["valid-working-sync-v1.json", "valid-working-sync-raw-opt-in-v1.json"] {
            let sync: RoomWorkingProjectSync = try workingSyncFixture(named: fixture)
            XCTAssertEqual(
                sync.assetPlanSHA256,
                try RoomRedesignContractDigests.workingSyncAssetPlanSHA256(
                    proposedRevision: sync.proposedRevision,
                    assetPolicy: sync.assetPolicy
                ),
                fixture
            )
            XCTAssertEqual(
                sync.selectionSHA256,
                try RoomRedesignContractDigests.workingSyncSelectionSHA256(assets: sync.assets),
                fixture
            )
        }

        let portal: RoomPortalSnapshot = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        XCTAssertEqual(
            portal.selectionSHA256,
            try RoomRedesignContractDigests.portalSnapshotSelectionSHA256(
                allowlistedSections: portal.allowlistedSections,
                assets: portal.assets,
                branding: portal.branding
            )
        )
    }

    func testCanonicalSelectionDigestsMatchPortableJSONGoldenVectors() throws {
        let aiExpected = [
            "valid-ai-ready-v1.json": "2939da89c7042ff142e36f81f9de43c402c6572051cc42eb8c9337fa2b89fa1a",
            "valid-ai-complete-v1.json": "e7fab5d9db92c2041ef7429e513e77f6a5c03961b7f15593d268a7cb698405dc"
        ]
        for (fixture, expected) in aiExpected {
            let package: RoomAIRoomPackage = try aiPackageFixture(named: fixture)
            XCTAssertEqual(
                try RoomRedesignContractDigests.aiSelectionSHA256(artifacts: package.artifacts),
                expected,
                fixture
            )
        }

        let syncExpected = [
            "valid-working-sync-v1.json": "9dabbbbc87514317f8181ffbe0a0a3c390bda5fd2ff3fd49d6596567157db233",
            "valid-working-sync-raw-opt-in-v1.json": "80324fcf6dd1086490b9c66ac64f029445f33b5acf7d99a0b396d8d5776e2bf8"
        ]
        for (fixture, expected) in syncExpected {
            let sync: RoomWorkingProjectSync = try workingSyncFixture(named: fixture)
            XCTAssertEqual(
                try RoomRedesignContractDigests.workingSyncSelectionSHA256(assets: sync.assets),
                expected,
                fixture
            )
        }

        let portal: RoomPortalSnapshot = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        XCTAssertEqual(
            try RoomRedesignContractDigests.portalSnapshotSelectionSHA256(
                allowlistedSections: portal.allowlistedSections,
                assets: portal.assets,
                branding: portal.branding
            ),
            "4ffcac54568243a1a217d1433e3d3a94ceeefa991e6058186bd02d3f033636cd"
        )

        var unicodeBranding = portal.branding
        unicodeBranding.displayName = "Café 🧭\u{2028}Studio"
        XCTAssertEqual(
            try RoomRedesignContractDigests.portalSnapshotSelectionSHA256(
                allowlistedSections: portal.allowlistedSections,
                assets: portal.assets,
                branding: unicodeBranding
            ),
            "8bab87bfcea118c86a648a13e715001c32bceb5c9e0abfeeed55d53b05a23132"
        )
    }

    func testStaticMalformedAndCrossVersionFixtureCorpusFailsClosed() throws {
        let fixtures = [
            "malformed-local-extension-v1.json",
            "unsupported-future-version.json",
            "unknown-source-package-schema.json",
            "cross-kind-discriminant.json",
            "raw-default-ai-ready.json",
            "world-map-ai-complete.json",
            "raw-default-working-sync.json",
            "precise-gps-ai-package.json",
            "private-snapshot-injection.json",
            "unknown-nested-snapshot-field.json",
            "unknown-nested-orientation-field.json",
            "revision-binding-orientation-epoch-mismatch.json",
            "malformed-artifact-disposition.json",
            "duplicate-included-artifact-path.json"
        ]

        for fixture in fixtures {
            assertRejected(try fixtureData(named: fixture), fixture)
        }
    }

    func testDuplicateJSONMembersFailClosedAtTopLevelAndNested() throws {
        let local = try fixtureString(named: "valid-local-extension-v1.json")
        let package = try fixtureString(named: "valid-ai-ready-v1.json")
        let cases: [(String, String, String)] = [
            (local, "\"schemaVersion\": \"roomscan-local-redesign-extension-v1\",", "schemaVersion"),
            (local, "\"contractKind\": \"localRedesignExtension\",", "contractKind"),
            (package, "\"profile\": \"aiReady\",", "profile"),
            (package, "\"artifactClass\": \"normalizedSemantics\",", "artifactClass"),
            (package, "\"disposition\": \"included\",", "disposition"),
            (package, "\"decision\": \"approved\",", "decision")
        ]
        for (source, member, label) in cases {
            let duplicate = try replacingFirst(
                in: source,
                target: member,
                replacement: "\(member)\n      \(member)"
            )
            assertRejected(Data(duplicate.utf8), "duplicate JSON member \(label)")
        }

        let escapedDuplicate = try replacingFirst(
            in: local,
            target: "\"contractKind\": \"localRedesignExtension\",",
            replacement: "\"contractKind\": \"localRedesignExtension\",\n  \"contract\\u004bind\": \"localRedesignExtension\","
        )
        assertRejected(Data(escapedDuplicate.utf8), "escaped duplicate member name")
    }

    func testDiscriminantsAndSourcePackageSchemaFailClosed() throws {
        let future = try mutateJSONFixture(named: "valid-local-extension-v1.json") {
            $0["schemaVersion"] = "roomscan-local-redesign-extension-v99"
        }
        assertRejected(future, "future schema")

        let crossKind = try mutateJSONFixture(named: "valid-local-extension-v1.json") {
            $0["schemaVersion"] = RoomRedesignContractKind.aiRoomPackage.supportedSchemaVersion
        }
        assertRejected(crossKind, "cross-kind schema/kind pair")

        let unsupportedSource = try mutateJSONFixture(named: "valid-local-extension-v1.json") { root in
            var source = root["sourceRevision"] as! [String: Any]
            source["packageSchemaVersion"] = "room-scan-project-v999"
            root["sourceRevision"] = source
        }
        assertInvalidValue(
            unsupportedSource,
            path: "sourceRevision.packageSchemaVersion",
            label: "unknown source package schema"
        )
    }

    func testLocalExtensionRejectsMalformedGeometryUnknownKeysAndRevisionRebinding() throws {
        let badConfidence = try mutateJSONFixture(named: "valid-local-extension-v1.json") { root in
            var orientation = root["orientation"] as! [String: Any]
            orientation["confidence"] = 1.5
            root["orientation"] = orientation
        }
        assertInvalidValue(badConfidence, path: "orientation.confidence", label: "bounded confidence")

        let wrongEpoch = try mutateJSONFixture(named: "valid-local-extension-v1.json") { root in
            var orientation = root["orientation"] as! [String: Any]
            orientation["coordinateSpaceEpochID"] = "epoch-999"
            root["orientation"] = orientation
        }
        assertInvalidValue(
            wrongEpoch,
            path: "orientation.coordinateSpaceEpochID",
            label: "orientation revision binding"
        )

        let reboundConcept = try mutateJSONFixture(named: "valid-local-extension-v1.json") { root in
            var concepts = root["conceptMetadata"] as! [[String: Any]]
            concepts[0]["sourceRevisionID"] = "revision-999"
            root["conceptMetadata"] = concepts
        }
        assertInvalidValue(
            reboundConcept,
            path: "conceptMetadata[0].sourceRevisionID",
            label: "concept revision binding"
        )

        let unknownNestedKey = try mutateJSONFixture(named: "valid-local-extension-v1.json") { root in
            var orientation = root["orientation"] as! [String: Any]
            orientation["serverSuggestedTransform"] = ["x": 0, "y": 0, "z": 0]
            root["orientation"] = orientation
        }
        assertRejected(unknownNestedKey, "unknown nested orientation key")
    }

    func testConceptAttachmentFixtureCarriesContentIdentity() throws {
        let root = try jsonObject(named: "valid-local-extension-v1.json")
        let concepts = try XCTUnwrap(root["conceptMetadata"] as? [[String: Any]])
        let concept = try XCTUnwrap(concepts.first)
        let attachments = try XCTUnwrap(concept["attachments"] as? [[String: Any]])
        let attachment = try XCTUnwrap(attachments.first)

        XCTAssertEqual(attachment["relativePath"] as? String, "concepts/concept-001/entry.png")
        XCTAssertEqual((attachment["sha256"] as? String)?.count, 64)
        XCTAssertEqual(attachment["byteCount"] as? Int, 4_096)
        XCTAssertEqual(attachment["mediaType"] as? String, "image/png")
        _ = try validateFixture(named: "valid-local-extension-v1.json")
    }

    func testConceptAttachmentRejectsMalformedContentIdentity() throws {
        let malformedDigest = try mutateJSONFixture(named: "valid-local-extension-v1.json") { root in
            var concepts = root["conceptMetadata"] as! [[String: Any]]
            var attachments = concepts[0]["attachments"] as! [[String: Any]]
            attachments[0]["sha256"] = "not-a-digest"
            concepts[0]["attachments"] = attachments
            root["conceptMetadata"] = concepts
        }
        assertInvalidValue(
            malformedDigest,
            path: "conceptMetadata[0].attachments[0].sha256",
            label: "Concept attachment digest"
        )

        let missingDigest = try mutateJSONFixture(named: "valid-local-extension-v1.json") { root in
            var concepts = root["conceptMetadata"] as! [[String: Any]]
            var attachments = concepts[0]["attachments"] as! [[String: Any]]
            attachments[0].removeValue(forKey: "sha256")
            concepts[0]["attachments"] = attachments
            root["conceptMetadata"] = concepts
        }
        assertRejected(missingDigest, "Concept attachment missing digest")
    }

    func testHostedResourceRejectsWorkspaceScopeSmuggling() throws {
        var resource: RoomHostedAPIResource = try hostedResourceFixture(named: "valid-hosted-resource-v1.json")
        resource.resourceType = .workspace
        assertInvalidValue(
            try encoded(resource),
            path: "resourceType",
            label: "workspace resource carrying project lineage"
        )
    }

    func testAIRoomPackageRequiresEveryBoundPlanSlotExactlyOnce() throws {
        let cases: [(String, RoomRedesignArtifactClass)] = [
            ("valid-ai-ready-v1.json", .canonicalView),
            ("valid-ai-complete-v1.json", .rawConfidence)
        ]

        for (fixture, omittedClass) in cases {
            var package: RoomAIRoomPackage = try aiPackageFixture(named: fixture)
            package.artifacts.removeAll { $0.artifactClass == omittedClass }
            try rebindSelection(&package)
            assertInvalidValue(try encoded(package), path: "artifacts", label: "missing slot in \(fixture)")

            package = try aiPackageFixture(named: fixture)
            var duplicate = try XCTUnwrap(package.artifacts.first)
            duplicate.artifactID = "artifact-duplicate-slot"
            package.artifacts.append(duplicate)
            assertInvalidValue(
                try encoded(package),
                path: "artifacts.artifactClass",
                label: "duplicate slot in \(fixture)"
            )
        }
    }

    func testAIRoomPackageRejectsPlanSelectionAndDisclosureReplay() throws {
        var package: RoomAIRoomPackage = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        package.artifactPlanSHA256 = zeroDigest
        package.disclosureReview.reviewedArtifactPlanSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(package),
            path: "artifactPlanSHA256",
            label: "artifact-plan digest mismatch"
        )

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        package.selectionSHA256 = zeroDigest
        package.disclosureReview.reviewedSelectionSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(package),
            path: "selectionSHA256",
            label: "selected-artifact digest mismatch"
        )

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        package.disclosureReview.sourceRevisionID = "revision-999"
        assertInvalidValue(
            try encoded(package),
            path: "disclosureReview.sourceRevisionID",
            label: "wrong-revision disclosure review"
        )

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        package.disclosureReview.reviewedSelectionSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(package),
            path: "disclosureReview.reviewedSelectionSHA256",
            label: "stale selected-artifact review"
        )

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        package.disclosureReview.reviewedArtifactPlanSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(package),
            path: "disclosureReview.reviewedArtifactPlanSHA256",
            label: "stale artifact-plan review"
        )

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        package.disclosureReview.decision = .rejected
        assertInvalidValue(
            try encoded(package),
            path: "disclosureReview.decision",
            label: "rejected disclosure review"
        )
    }

    func testAIReadyRejectsIncludedRawEvidence() throws {
        var package: RoomAIRoomPackage = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let rawSlot = RoomAIArtifactSlot(
            artifactID: "artifact-raw-rgb",
            artifactClass: .rawRGB
        )
        package.artifactPlan.append(rawSlot)
        package.artifacts.append(RoomAIRoomPackageArtifact(
            artifactID: rawSlot.artifactID,
            artifactClass: .rawRGB,
            disposition: .included,
            relativePath: "raw/artifact-raw-rgb.heic",
            sha256: String(repeating: "c", count: 64),
            byteCount: 16_384,
            mediaType: "image/heic"
        ))
        package.artifactPlanSHA256 = try RoomRedesignContractDigests.aiArtifactPlanSHA256(
            sourceRevision: package.sourceRevision,
            profile: package.profile,
            slots: package.artifactPlan
        )
        package.disclosureReview.reviewedArtifactPlanSHA256 = package.artifactPlanSHA256
        try rebindSelection(&package)

        assertInvalidValue(
            try encoded(package),
            path: "artifactPlan",
            label: "AI-ready raw-default guard"
        )
    }

    func testBothAIProfilesRejectWorldMaps() throws {
        for fixture in ["valid-ai-ready-v1.json", "valid-ai-complete-v1.json"] {
            var package: RoomAIRoomPackage = try aiPackageFixture(named: fixture)
            package.artifacts.append(
                RoomAIRoomPackageArtifact(
                    artifactID: "artifact-world-map",
                    artifactClass: .worldMap,
                    disposition: .excluded,
                    reasonCode: "private-capture-state"
                )
            )
            try rebindSelection(&package)
            assertInvalidValue(try encoded(package), path: "artifacts", label: "world map in \(fixture)")
        }
    }

    func testPreciseGPSIsAbsentAndRejectedByAIContract() throws {
        XCTAssertFalse(RoomRedesignArtifactClass.allCases.map(\.rawValue).contains("preciseGPS"))
        let injectedGPS = try mutateJSONFixture(named: "valid-ai-complete-v1.json") {
            $0["preciseGPS"] = ["latitude": 40.7128, "longitude": -74.0060]
        }
        assertRejected(injectedGPS, "precise GPS injection")
    }

    func testArtifactStateAndIncludedPathUniquenessFailClosed() throws {
        var package: RoomAIRoomPackage = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let includedIndex = try XCTUnwrap(package.artifacts.firstIndex { $0.disposition == .included })
        package.artifacts[includedIndex].sha256 = nil
        assertInvalidValue(
            try encoded(package),
            path: "artifacts[\(includedIndex)]",
            label: "included artifact missing digest"
        )

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let firstIndex = try XCTUnwrap(package.artifacts.firstIndex { $0.artifactClass == .canonicalView })
        let secondIndex = try XCTUnwrap(package.artifacts.firstIndex { $0.artifactClass == .selectedReferenceImage })
        package.artifacts[secondIndex].relativePath = package.artifacts[firstIndex].relativePath
        assertInvalidValue(
            try encoded(package),
            path: "artifacts.included.relativePath",
            label: "duplicate included artifact path"
        )

        let malformedDisposition = try mutateJSONFixture(named: "valid-ai-ready-v1.json") { root in
            var artifacts = root["artifacts"] as! [[String: Any]]
            artifacts[0]["disposition"] = "teleported"
            root["artifacts"] = artifacts
        }
        assertRejected(malformedDisposition, "malformed artifact disposition")
    }

    func testOutboundRelativePathsRejectControlCharacters() throws {
        var package: RoomAIRoomPackage = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let index = try XCTUnwrap(package.artifacts.firstIndex { $0.disposition == .included })
        package.artifacts[index].relativePath = "images/unsafe\nname.jpg"
        try rebindSelection(&package)
        assertInvalidValue(
            try encoded(package),
            path: "artifacts[\(index)].relativePath",
            label: "control character in outbound relative path"
        )
    }

    func testOutboundPathIdentityRejectsCaseAndUnicodeAliases() throws {
        var package: RoomAIRoomPackage = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let firstIndex = try XCTUnwrap(package.artifacts.firstIndex { $0.artifactClass == .canonicalView })
        let secondIndex = try XCTUnwrap(package.artifacts.firstIndex { $0.artifactClass == .selectedReferenceImage })
        package.artifacts[firstIndex].relativePath = "images/HERO.jpg"
        package.artifacts[secondIndex].relativePath = "images/hero.jpg"
        try rebindSelection(&package)
        assertInvalidValue(
            try encoded(package),
            path: "artifacts.included.relativePath",
            label: "case-aliased outbound paths"
        )

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let includedIndex = try XCTUnwrap(package.artifacts.firstIndex { $0.disposition == .included })
        package.artifacts[includedIndex].relativePath = "images/Cafe\u{301}.jpg"
        try rebindSelection(&package)
        assertInvalidValue(
            try encoded(package),
            path: "artifacts[\(includedIndex)].relativePath",
            label: "non-ASCII outbound path with normalization aliases"
        )
    }

    func testCompleteProfileCanCarryRawEvidenceAfterDisclosureReview() throws {
        let document = try validateFixture(named: "valid-ai-complete-v1.json")
        guard case let .aiRoomPackage(package) = document else {
            return XCTFail("Expected AI Room Package fixture.")
        }

        XCTAssertEqual(package.profile, .complete)
        XCTAssertTrue(package.disclosureReview.rawEvidenceDisclosureAccepted)
        XCTAssertTrue(package.artifacts.contains {
            $0.artifactClass == .rawRGB && $0.disposition == .included
        })
    }

    func testWorkingSyncRequiresEveryPolicySlotExactlyOnce() throws {
        let cases: [(String, RoomRedesignArtifactClass)] = [
            ("valid-working-sync-v1.json", .mesh),
            ("valid-working-sync-raw-opt-in-v1.json", .worldMap)
        ]

        for (fixture, omittedClass) in cases {
            var sync: RoomWorkingProjectSync = try workingSyncFixture(named: fixture)
            sync.assets.removeAll { $0.assetClass == omittedClass }
            try rebindSelection(&sync)
            assertInvalidValue(try encoded(sync), path: "assets", label: "missing sync slot in \(fixture)")

            sync = try workingSyncFixture(named: fixture)
            var duplicate = try XCTUnwrap(sync.assets.first)
            duplicate.assetID = "asset-duplicate-slot"
            sync.assets.append(duplicate)
            assertInvalidValue(
                try encoded(sync),
                path: "assets.assetClass",
                label: "duplicate sync slot in \(fixture)"
            )
        }
    }

    func testWorkingSetRejectsRawAssetOutsideItsBoundPlan() throws {
        var sync: RoomWorkingProjectSync = try workingSyncFixture(named: "valid-working-sync-v1.json")
        sync.assets.append(
            RoomWorkingProjectSyncAsset(
                assetID: "asset-raw-depth-outside-plan",
                assetClass: .rawDepth,
                disposition: .included,
                relativePath: "raw/depth/frame-0001.bin",
                sha256: String(repeating: "7", count: 64),
                byteCount: 8_192,
                mediaType: "application/octet-stream"
            )
        )
        try rebindSelection(&sync)
        assertInvalidValue(
            try encoded(sync),
            path: "assets",
            label: "working-set structural raw-default guard"
        )
    }

    func testWorkingSyncRejectsPlanSelectionAndDisclosureReplay() throws {
        var sync: RoomWorkingProjectSync = try workingSyncFixture(named: "valid-working-sync-v1.json")
        sync.assetPlanSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(sync),
            path: "assetPlanSHA256",
            label: "working-sync plan digest mismatch"
        )

        sync = try workingSyncFixture(named: "valid-working-sync-v1.json")
        sync.selectionSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(sync),
            path: "selectionSHA256",
            label: "working-sync selection digest mismatch"
        )

        sync = try workingSyncFixture(named: "valid-working-sync-raw-opt-in-v1.json")
        sync.rawArchiveDisclosureReview?.sourceRevisionID = "revision-999"
        assertInvalidValue(
            try encoded(sync),
            path: "rawArchiveDisclosureReview.sourceRevisionID",
            label: "raw archive wrong-revision review"
        )

        sync = try workingSyncFixture(named: "valid-working-sync-raw-opt-in-v1.json")
        sync.rawArchiveDisclosureReview?.reviewedSelectionSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(sync),
            path: "rawArchiveDisclosureReview.reviewedSelectionSHA256",
            label: "raw archive stale-selection review"
        )

        sync = try workingSyncFixture(named: "valid-working-sync-raw-opt-in-v1.json")
        sync.rawArchiveDisclosureReview?.reviewedArtifactPlanSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(sync),
            path: "rawArchiveDisclosureReview.reviewedArtifactPlanSHA256",
            label: "raw archive stale-plan review"
        )

        sync = try workingSyncFixture(named: "valid-working-sync-raw-opt-in-v1.json")
        sync.rawArchiveDisclosureReview?.rawEvidenceDisclosureAccepted = false
        assertInvalidValue(
            try encoded(sync),
            path: "rawArchiveDisclosureReview.rawEvidenceDisclosureAccepted",
            label: "raw archive disclosure not accepted"
        )
    }

    func testExplicitRawArchiveOptInCanCarryRawEvidence() throws {
        let document = try validateFixture(named: "valid-working-sync-raw-opt-in-v1.json")
        guard case let .workingProjectSync(sync) = document else {
            return XCTFail("Expected working-project sync fixture.")
        }

        XCTAssertEqual(sync.assetPolicy, .rawArchiveOptIn)
        XCTAssertTrue(sync.rawArchiveDisclosureReview?.rawEvidenceDisclosureAccepted == true)
        XCTAssertTrue(sync.assets.contains {
            $0.assetClass == .rawDepth && $0.disposition == .included
        })
    }

    func testPortalSnapshotAllowlistAndReviewFailClosed() throws {
        let privateRoot = try mutateJSONFixture(named: "valid-portal-snapshot-v1.json") {
            $0["privateNotes"] = "never publish"
        }
        assertRejected(privateRoot, "private portal root injection")

        let nestedWorldMap = try mutateJSONFixture(named: "valid-portal-snapshot-v1.json") { root in
            var assets = root["assets"] as! [[String: Any]]
            assets[0]["worldMap"] = "private/world-map.bin"
            root["assets"] = assets
        }
        assertRejected(nestedWorldMap, "nested portal world-map injection")

        let genericDownload = try mutateJSONFixture(named: "valid-portal-snapshot-v1.json") { root in
            var assets = root["assets"] as! [[String: Any]]
            assets[0]["assetClass"] = "download"
            assets[0]["relativePath"] = "downloads/private-project.zip"
            assets[0]["mediaType"] = "application/zip"
            root["assets"] = assets
        }
        assertRejected(genericDownload, "generic portal download")

        var snapshot: RoomPortalSnapshot = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        let packageIndex = try XCTUnwrap(snapshot.assets.firstIndex { $0.assetClass == .aiReadyPackage })
        snapshot.assets[packageIndex].relativePath = "downloads/complete-raw-package.zip"
        try rebindSelection(&snapshot)
        XCTAssertNoThrow(try RoomRedesignContractValidator.validate(data: encoded(snapshot)))

        snapshot = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        snapshot.disclosureReview.reviewedSelectionSHA256 = zeroDigest
        assertInvalidValue(
            try encoded(snapshot),
            path: "disclosureReview.reviewedSelectionSHA256",
            label: "stale portal disclosure review"
        )
    }

    func testPortalAIReadyDownloadBindsAndValidatesActualArchiveManifestBytes() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomRedesignPortalArchiveTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        var snapshot: RoomPortalSnapshot = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        let packageIndex = try XCTUnwrap(snapshot.assets.firstIndex { $0.assetClass == .aiReadyPackage })
        snapshot.assets[packageIndex].relativePath = "downloads/private-project.zip"
        snapshot.assets[packageIndex].aiReadyPackageBinding = nil
        try rebindSelection(&snapshot)

        assertInvalidValue(
            try encoded(snapshot),
            path: "assets[\(packageIndex)].aiReadyPackageBinding",
            label: "neutral filename without a validated AI-ready manifest binding"
        )

        var package: RoomAIRoomPackage = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let built = try await buildAIArchive(
            package: &package,
            in: temporaryRoot.appendingPathComponent("valid", isDirectory: true)
        )
        snapshot = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        snapshot.assets[packageIndex].sha256 = built.receipt.archiveSHA256
        snapshot.assets[packageIndex].byteCount = built.receipt.archiveByteCount
        snapshot.assets[packageIndex].aiReadyPackageBinding = binding(for: package, manifestData: built.manifestData)
        try rebindSelection(&snapshot)

        let validExtraction = temporaryRoot.appendingPathComponent("valid-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: validExtraction, withIntermediateDirectories: true)
        let validatedPackage = try await RoomRedesignContractValidator.validatePortalAIReadyDownload(
            snapshot: snapshot,
            assetID: snapshot.assets[packageIndex].assetID,
            archiveURL: built.archiveURL,
            extractionDirectoryURL: validExtraction
        )
        XCTAssertEqual(validatedPackage.profile, .aiReady)

        var completePackage: RoomAIRoomPackage = try aiPackageFixture(named: "valid-ai-complete-v1.json")
        let complete = try await buildAIArchive(
            package: &completePackage,
            in: temporaryRoot.appendingPathComponent("complete", isDirectory: true)
        )
        var disguised = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        disguised.assets[packageIndex].relativePath = "downloads/ai-ready-package.zip"
        disguised.assets[packageIndex].sha256 = complete.receipt.archiveSHA256
        disguised.assets[packageIndex].byteCount = complete.receipt.archiveByteCount
        var disguisedBinding = binding(for: completePackage, manifestData: complete.manifestData)
        disguisedBinding.profile = .aiReady
        disguisedBinding.artifactPlanSHA256 = try RoomRedesignContractDigests.aiArtifactPlanSHA256(
            sourceRevision: completePackage.sourceRevision,
            profile: .aiReady
        )
        disguised.assets[packageIndex].aiReadyPackageBinding = disguisedBinding
        try rebindSelection(&disguised)
        try disguised.validate() // Control: the outer snapshot is valid.
        let completeExtraction = temporaryRoot.appendingPathComponent("complete-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: completeExtraction, withIntermediateDirectories: true)
        do {
            _ = try await RoomRedesignContractValidator.validatePortalAIReadyDownload(
                snapshot: disguised,
                assetID: disguised.assets[packageIndex].assetID,
                archiveURL: complete.archiveURL,
                extractionDirectoryURL: completeExtraction
            )
            XCTFail("A renamed Complete/raw archive must fail based on its manifest bytes.")
        } catch let error as RoomRedesignContractValidationError {
            guard case let .invalidValue(path, _) = error else {
                return XCTFail("Expected invalidValue for renamed Complete archive, got \(error)")
            }
            XCTAssertEqual(path, "assets.\(disguised.assets[packageIndex].assetID).aiReadyPackageBinding")
        } catch {
            XCTFail("Unexpected renamed Complete archive error: \(error)")
        }

        package = try aiPackageFixture(named: "valid-ai-ready-v1.json")
        let hiddenRaw = try await buildAIArchive(
            package: &package,
            in: temporaryRoot.appendingPathComponent("hidden-raw", isDirectory: true),
            extraEntry: ("raw/hidden-frame.bin", Data("private raw bytes".utf8))
        )
        var hidden = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        hidden.assets[packageIndex].sha256 = hiddenRaw.receipt.archiveSHA256
        hidden.assets[packageIndex].byteCount = hiddenRaw.receipt.archiveByteCount
        hidden.assets[packageIndex].aiReadyPackageBinding = binding(
            for: package,
            manifestData: hiddenRaw.manifestData
        )
        try rebindSelection(&hidden)
        try hidden.validate() // Control: only byte-level archive closure is bad.
        let hiddenExtraction = temporaryRoot.appendingPathComponent("hidden-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenExtraction, withIntermediateDirectories: true)
        do {
            _ = try await RoomRedesignContractValidator.validatePortalAIReadyDownload(
                snapshot: hidden,
                assetID: hidden.assets[packageIndex].assetID,
                archiveURL: hiddenRaw.archiveURL,
                extractionDirectoryURL: hiddenExtraction
            )
            XCTFail("An unledgered hidden raw entry must fail archive closure.")
        } catch let error as RoomRedesignContractValidationError {
            guard case let .invalidValue(path, _) = error else {
                return XCTFail("Expected invalidValue for hidden raw archive entry, got \(error)")
            }
            XCTAssertEqual(path, "assets.\(hidden.assets[packageIndex].assetID).aiReadyPackageBinding")
        } catch {
            XCTFail("Unexpected hidden raw archive error: \(error)")
        }
    }

    func testPortalAssetRequiresItsExplicitAllowlistSection() throws {
        var snapshot = try portalSnapshotFixture(named: "valid-portal-snapshot-v1.json")
        snapshot.allowlistedSections.removeAll { $0 == .webGeometry }
        try rebindSelection(&snapshot)
        assertInvalidValue(
            try encoded(snapshot),
            path: "assets[0].assetClass",
            label: "portal asset without its explicit section"
        )
    }

    func testPortalDownloadsAreExplicitPositiveAllowlist() throws {
        let document = try validateFixture(named: "valid-portal-snapshot-v1.json")
        guard case let .portalSnapshot(snapshot) = document else {
            return XCTFail("Expected portal snapshot fixture.")
        }
        let downloads = Set(snapshot.assets.map(\.assetClass)).intersection([
            .floorPlanPDF,
            .approvedGalleryZIP,
            .aiReadyPackage
        ])
        XCTAssertEqual(downloads, [.floorPlanPDF, .approvedGalleryZIP, .aiReadyPackage])
    }

    private let zeroDigest = String(repeating: "0", count: 64)

    private func validateFixture(named name: String) throws -> RoomRedesignContractDocument {
        try RoomRedesignContractValidator.validate(data: fixtureData(named: name))
    }

    private func aiPackageFixture(named name: String) throws -> RoomAIRoomPackage {
        guard case let .aiRoomPackage(package) = try validateFixture(named: name) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return package
    }

    private func workingSyncFixture(named name: String) throws -> RoomWorkingProjectSync {
        guard case let .workingProjectSync(sync) = try validateFixture(named: name) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return sync
    }

    private func portalSnapshotFixture(named name: String) throws -> RoomPortalSnapshot {
        guard case let .portalSnapshot(snapshot) = try validateFixture(named: name) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return snapshot
    }

    private func hostedResourceFixture(named name: String) throws -> RoomHostedAPIResource {
        guard case let .hostedAPIResource(resource) = try validateFixture(named: name) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return resource
    }

    private func fixtureData(named name: String) throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RedesignContracts")
            .appendingPathComponent(name)
        return try Data(contentsOf: fixtureURL)
    }

    private func fixtureString(named name: String) throws -> String {
        guard let value = String(data: try fixtureData(named: name), encoding: .utf8) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return value
    }

    private func replacingFirst(in value: String, target: String, replacement: String) throws -> String {
        guard let range = value.range(of: target) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        var result = value
        result.replaceSubrange(range, with: replacement)
        return result
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        try RoomJSONCoding.makeEncoder().encode(value)
    }

    private func mutateJSONFixture(
        named name: String,
        mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var root = try jsonObject(named: name)
        try mutation(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func jsonObject(named name: String) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: fixtureData(named: name)) as? [String: Any] else {
            throw RoomRedesignContractValidationError.rootMustBeObject
        }
        return root
    }

    private func rebindSelection(_ package: inout RoomAIRoomPackage) throws {
        let digest = try RoomRedesignContractDigests.aiSelectionSHA256(artifacts: package.artifacts)
        package.selectionSHA256 = digest
        package.disclosureReview.reviewedSelectionSHA256 = digest
    }

    private func rebindSelection(_ sync: inout RoomWorkingProjectSync) throws {
        let digest = try RoomRedesignContractDigests.workingSyncSelectionSHA256(assets: sync.assets)
        sync.selectionSHA256 = digest
        sync.rawArchiveDisclosureReview?.reviewedSelectionSHA256 = digest
    }

    private func rebindSelection(_ snapshot: inout RoomPortalSnapshot) throws {
        let digest = try RoomRedesignContractDigests.portalSnapshotSelectionSHA256(
            allowlistedSections: snapshot.allowlistedSections,
            assets: snapshot.assets,
            branding: snapshot.branding
        )
        snapshot.selectionSHA256 = digest
        snapshot.disclosureReview.reviewedSelectionSHA256 = digest
    }

    private struct BuiltAIArchive {
        var archiveURL: URL
        var receipt: RoomZIPArchiveReceipt
        var manifestData: Data
    }

    private func binding(
        for package: RoomAIRoomPackage,
        manifestData: Data
    ) -> RoomPortalAIReadyPackageBinding {
        RoomPortalAIReadyPackageBinding(
            packageID: package.packageID,
            profile: .aiReady,
            manifestEntryPath: "ai-room-package.json",
            manifestSHA256: RoomSHA256.hexDigest(of: manifestData),
            sourceRevisionID: package.sourceRevision.revisionID,
            sourceRevisionManifestSHA256: package.sourceRevision.revisionManifestSHA256,
            artifactPlanSHA256: package.artifactPlanSHA256,
            selectionSHA256: package.selectionSHA256
        )
    }

    private func buildAIArchive(
        package: inout RoomAIRoomPackage,
        in root: URL,
        extraEntry: (path: String, data: Data)? = nil
    ) async throws -> BuiltAIArchive {
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        var inputs: [RoomZIPInput] = []

        for index in package.artifacts.indices where package.artifacts[index].disposition == .included {
            let relativePath = try XCTUnwrap(package.artifacts[index].relativePath)
            let bytes = Data("fixture-bytes-\(package.artifacts[index].artifactID)".utf8)
            package.artifacts[index].sha256 = RoomSHA256.hexDigest(of: bytes)
            package.artifacts[index].byteCount = UInt64(bytes.count)
            let sourceURL = sourceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: sourceURL, options: [.withoutOverwriting])
            inputs.append(RoomZIPInput(
                sourceURL: sourceURL,
                entryPath: try RoomExportEntryPath(relativePath),
                mediaType: try XCTUnwrap(package.artifacts[index].mediaType)
            ))
        }

        try rebindSelection(&package)
        let manifestData = try encoded(package)
        let manifestURL = sourceRoot.appendingPathComponent("ai-room-package.json")
        try manifestData.write(to: manifestURL, options: [.withoutOverwriting])
        inputs.append(RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath("ai-room-package.json"),
            mediaType: "application/json"
        ))

        if let extraEntry {
            let extraURL = sourceRoot.appendingPathComponent(extraEntry.path)
            try FileManager.default.createDirectory(
                at: extraURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try extraEntry.data.write(to: extraURL, options: [.withoutOverwriting])
            inputs.append(RoomZIPInput(
                sourceURL: extraURL,
                entryPath: try RoomExportEntryPath(extraEntry.path),
                mediaType: "application/octet-stream"
            ))
        }

        let archiveURL = root.appendingPathComponent("package.zip")
        let receipt = try await RoomDeterministicZIP.write(inputs: inputs, to: archiveURL)
        return BuiltAIArchive(
            archiveURL: archiveURL,
            receipt: receipt,
            manifestData: manifestData
        )
    }

    private func assertRejected(
        _ data: Data,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RoomRedesignContractValidator.validate(data: data),
            label,
            file: file,
            line: line
        )
    }

    private func assertInvalidValue(
        _ data: Data,
        path expectedPath: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try RoomRedesignContractValidator.validate(data: data)
            XCTFail("Expected invalid value: \(label)", file: file, line: line)
        } catch let error as RoomRedesignContractValidationError {
            guard case let .invalidValue(actualPath, _) = error else {
                return XCTFail("Expected invalidValue for \(label), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(actualPath, expectedPath, label, file: file, line: line)
        } catch {
            XCTFail("Unexpected error for \(label): \(error)", file: file, line: line)
        }
    }
}
