import AVFoundation
import CoreLocation
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
}
