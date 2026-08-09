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
}
