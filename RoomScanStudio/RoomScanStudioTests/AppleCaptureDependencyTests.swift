import AVFoundation
import CoreLocation
import UIKit
import XCTest
import RoomScanCore
@testable import RoomScanStudio

@MainActor
final class AppleCaptureDependencyTests: XCTestCase {
    func testCameraAuthorizationMappingIsPureAndDoesNotRequestHardware() {
        XCTAssertEqual(
            AppleCameraPermissionProvider.capturePermission(for: .authorized),
            .authorized
        )
        XCTAssertEqual(
            AppleCameraPermissionProvider.capturePermission(for: .denied),
            .denied
        )
        XCTAssertEqual(
            AppleCameraPermissionProvider.capturePermission(for: .restricted),
            .denied
        )
        XCTAssertEqual(
            AppleCameraPermissionProvider.capturePermission(for: .notDetermined),
            .unknown
        )
    }

    func testLocationAuthorizationMappingKeepsNoFixNonfatal() {
        XCTAssertEqual(
            AppleLocationProvider.capturePermission(for: .authorizedWhenInUse),
            .authorized
        )
        XCTAssertEqual(
            AppleLocationProvider.capturePermission(for: .denied),
            .denied
        )
        XCTAssertEqual(
            AppleLocationProvider.capturePermission(for: .restricted),
            .denied
        )
        XCTAssertEqual(
            AppleLocationProvider.capturePermission(for: .notDetermined),
            .unknown
        )
        XCTAssertEqual(
            AppleLocationProvider.locationServicesResult(servicesEnabled: false),
            .denied
        )
    }

    func testStaleOneShotLocationCompletesAsNoFixRatherThanLeakingRequest() {
        let requestStartedAt = Date(timeIntervalSince1970: 1_704_067_200)
        let stale = RoomGPSLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            horizontalAccuracyMeters: 12,
            capturedAt: requestStartedAt.addingTimeInterval(-1)
        )

        XCTAssertEqual(
            AppleLocationProvider.oneShotResult(
                location: stale,
                requestStartedAt: requestStartedAt
            ),
            .authorized(nil)
        )
    }

    func testRoomPlanDeltaPolicyAcceptsOnlyDidUpdateAsAFullSnapshot() {
        XCTAssertFalse(
            AppleRoomCaptureDriver.acceptsFullSnapshot(
                from: .didAdd
            )
        )
        XCTAssertFalse(
            AppleRoomCaptureDriver.acceptsFullSnapshot(
                from: .didRemove
            )
        )
        XCTAssertFalse(
            AppleRoomCaptureDriver.acceptsFullSnapshot(
                from: .didChange
            )
        )
        XCTAssertTrue(
            AppleRoomCaptureDriver.acceptsFullSnapshot(
                from: .didUpdate
            )
        )
    }

    func testProductionDriverFactoryDeclaresRoomPlanAvailabilitySeam() {
        XCTAssertTrue(AppleRoomCaptureDriverFactory.usesOneAppOwnedSessionPerDriver)
        XCTAssertTrue(AppleRoomCaptureDriverFactory.finalStopPausesARSession)
    }

    /// Device RoomPlan values can contain non-finite floats. The strict app
    /// encoder rejects them (the exact failure observed as "The data couldn't
    /// be written because it isn't in the correct format" on first device
    /// run); the evidence encoder must accept them.
    func testEvidenceEncoderAcceptsNonFiniteFloatsWhereStrictEncoderFails() throws {
        let nonFinite: [Float] = [.nan, .infinity, -.infinity, 1.5]

        XCTAssertThrowsError(
            try RoomJSONCoding.makeEncoder().encode(nonFinite)
        ) { error in
            XCTAssertTrue(error is EncodingError)
        }

        let encoded = try AppleRoomCaptureDriver.makeEvidenceEncoder().encode(nonFinite)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("\"NaN\""))
        XCTAssertTrue(json.contains("\"Infinity\""))
        XCTAssertTrue(json.contains("\"-Infinity\""))

        let roundTripped = try AppleRoomCaptureDriver.makeEvidenceDecoder()
            .decode([Float].self, from: encoded)
        XCTAssertTrue(roundTripped[0].isNaN)
        XCTAssertEqual(roundTripped[1], .infinity)
        XCTAssertEqual(roundTripped[2], -.infinity)
        XCTAssertEqual(roundTripped[3], 1.5)
    }

    func testCaptureBundlePLYWriterProducesWellFormedBinaryPLY() throws {
        let vertices: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
        ]
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        let faces: [UInt32] = [0, 1, 2, 1, 3, 2]

        let ply = RoomCaptureBundlePLYWriter.makeBinaryPLY(
            vertices: vertices,
            normals: normals,
            faces: faces
        )
        let headerTerminator = Data("end_header\n".utf8)
        let terminatorRange = try XCTUnwrap(ply.range(of: headerTerminator))
        let header = String(decoding: ply[..<terminatorRange.upperBound], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
        XCTAssertTrue(header.contains("element vertex 4\n"))
        XCTAssertTrue(header.contains("element face 2\n"))
        // 4 vertices x 6 floats x 4 bytes + 2 faces x (1 count byte + 3 x 4-byte indices).
        XCTAssertEqual(ply.count - terminatorRange.upperBound, 4 * 24 + 2 * 13)
    }

    func testCaptureBundleManifestRoundTripsThroughJSON() throws {
        let manifest = RoomCaptureBundleManifest(
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_754_784_000),
            frames: [
                RoomCaptureBundleFrame(
                    fileName: "frame-00001.jpg",
                    timestamp: 12.5,
                    cameraTransform: (0..<16).map(Double.init),
                    intrinsics: (0..<9).map(Double.init),
                    imageWidth: 1920,
                    imageHeight: 1440,
                    exposureDuration: 0.008
                ),
            ],
            meshAnchorCount: 3,
            meshVertexCount: 120,
            meshFaceCount: 200,
            notes: ["test note"]
        )
        let data = try RoomJSONCoding.makeEncoder().encode(manifest)
        let decoded = try RoomJSONCoding.makeDecoder().decode(
            RoomCaptureBundleManifest.self,
            from: data
        )
        XCTAssertEqual(decoded, manifest)
    }

    func testPostStopQualityAnalyzerReusesPosedFramesAndLocalizesBlurWithoutCoverageCollapse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomQualityAnalyzer-\(UUID().uuidString)", isDirectory: true)
        let framesURL = root.appendingPathComponent(RoomCaptureBundleLibrary.framesSubdirectoryName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)

        let identity: [Double] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        let intrinsics: [Double] = [80, 0, 0, 0, 80, 0, 50, 50, 1]
        let frames = (0..<4).map { index -> RoomCaptureBundleFrame in
            let east = index < 2
            let fileName = String(format: "frame-%05d.jpg", index + 1)
            let data = east ? flatJPEG() : checkerboardJPEG()
            try! data.write(to: framesURL.appendingPathComponent(fileName), options: .atomic)
            var transform = identity
            transform[12] = east ? 2 : -2
            return RoomCaptureBundleFrame(
                fileName: fileName,
                timestamp: Double(index + 1),
                cameraTransform: transform,
                intrinsics: intrinsics,
                imageWidth: 100,
                imageHeight: 100,
                exposureDuration: 0.01
            )
        }
        let manifest = RoomCaptureBundleManifest(
            schemaVersion: RoomCaptureBundleManifest.currentSchemaVersion,
            createdAt: Date(timeIntervalSince1970: 1_704_067_200),
            frames: frames,
            meshAnchorCount: 0,
            meshVertexCount: 0,
            meshFaceCount: 0,
            notes: []
        )
        try RoomJSONCoding.makeEncoder().encode(manifest).write(
            to: root.appendingPathComponent(RoomCaptureBundleLibrary.manifestFileName),
            options: .atomic
        )
        let snapshot = qualitySnapshot()
        let assessment = try RoomCaptureQualityAnalyzer.analyze(
            snapshot: snapshot,
            coordinateSpaceEpochID: "epoch-001",
            bundleDirectoryURL: root,
            trackingSamples: [
                .init(
                    sequence: 1,
                    timestamp: 1,
                    quality: .normal,
                    limitedReason: nil,
                    cameraTransform: identity,
                    intrinsics: intrinsics,
                    imageWidth: 100,
                    imageHeight: 100
                ),
            ]
        )

        XCTAssertEqual(assessment.advisoryFindings.map(\.dimension), [.visualSharpness])
        XCTAssertEqual(assessment.advisoryFindings.first?.affectedRegion?.regionID, "east-wall")
        XCTAssertEqual(assessment.records[1].state, .acceptable)
        XCTAssertEqual(assessment.records[2].state, .acceptable)
        XCTAssertEqual(assessment.records[3].state, .acceptable)
    }

    func testMissingPostStopImageSourceFailsSafelyToUnavailableGeneralGuidance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomQualityAnalyzerMissing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assessment = try RoomCaptureQualityAnalyzer.analyze(
            snapshot: qualitySnapshot(),
            coordinateSpaceEpochID: "epoch-001",
            bundleDirectoryURL: root,
            trackingSamples: []
        )
        XCTAssertEqual(assessment.records[0].state, .unavailable)
        XCTAssertEqual(assessment.records[1].state, .unavailable)
        XCTAssertEqual(assessment.records[2].state, .insufficientEvidence)
        XCTAssertTrue(assessment.advisoryFindings.isEmpty)
    }

    func testCaptureBundleLibraryAdoptionReplacesPriorBundleAndIsDiscoverable() throws {
        let projectID = "test-bundle-project-\(UUID().uuidString.lowercased())"
        defer { try? RoomCaptureBundleLibrary.removeBundle(forProject: projectID) }

        let scratchA = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratchA, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: scratchA.appendingPathComponent("marker.txt"))
        try RoomCaptureBundleLibrary.adoptBundle(at: scratchA, forProject: projectID)

        let adopted = try XCTUnwrap(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
        XCTAssertEqual(
            try String(contentsOf: adopted.appendingPathComponent("marker.txt"), encoding: .utf8),
            "first"
        )

        let scratchB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratchB, withIntermediateDirectories: true)
        try Data("second".utf8).write(to: scratchB.appendingPathComponent("marker.txt"))
        try RoomCaptureBundleLibrary.adoptBundle(at: scratchB, forProject: projectID)

        let replaced = try XCTUnwrap(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
        XCTAssertEqual(
            try String(contentsOf: replaced.appendingPathComponent("marker.txt"), encoding: .utf8),
            "second"
        )

        try RoomCaptureBundleLibrary.removeBundle(forProject: projectID)
        XCTAssertNil(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
    }

    private func qualitySnapshot() -> RoomSemanticSnapshot {
        let provenance = RoomElementProvenance(
            framework: "quality-test",
            sourceIdentifier: "quality-test-source",
            classificationConfidence: .high,
            captureAttemptID: "attempt-001",
            coordinateSpaceEpochID: "epoch-001"
        )
        func wall(id: String, x: Double) -> RoomSemanticElement {
            RoomSemanticElement(
                id: id,
                kind: "wall",
                label: id == "east-wall" ? "East wall" : "West wall",
                dimensionsMeters: .init(width: 1, height: 1, depth: 0.08),
                transform: .init(columnMajorValues: [
                    1, 0, 0, 0,
                    0, 1, 0, 0,
                    0, 0, 1, 0,
                    x, 0, -2, 1,
                ]),
                provenance: provenance,
                mobility: .structural,
                origin: .deterministicFixture
            )
        }
        return .init(
            projectID: "pending-project",
            revisionID: "pending-revision",
            units: "meters",
            accuracyDisclaimer: RoomCaptureState.nonSurveyAccuracyDisclaimer,
            structuralElements: [wall(id: "east-wall", x: 2), wall(id: "west-wall", x: -2)],
            objectElements: []
        )
    }

    private func flatJPEG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 0.95)!
    }

    private func checkerboardJPEG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            for y in 0..<8 {
                for x in 0..<8 {
                    (x + y).isMultiple(of: 2) ? UIColor.white.setFill() : UIColor.black.setFill()
                    context.cgContext.fill(CGRect(x: x * 8, y: y * 8, width: 8, height: 8))
                }
            }
        }.jpegData(compressionQuality: 0.95)!
    }
}
