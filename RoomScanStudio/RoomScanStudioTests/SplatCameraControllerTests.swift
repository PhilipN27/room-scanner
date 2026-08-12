import RoomScanCore
import XCTest
import simd
@testable import RoomScanStudio

/// `SplatCameraController` is the shared first-person walk camera behind
/// both the colored-mesh and splat Metal viewers (`RoomMeshViewer.swift`,
/// `RoomSplatViewer.swift`). These tests exercise its `tick(deltaTime:)`
/// math and mode-transition hygiene directly, without any MTKView or Metal
/// device — the same guarantees `RoomViewerCameraReducer` already has in
/// RoomScanCore (walk speed 1.6 m/s, 0.1 dead zone, 0.1s delta cap).
@MainActor
final class SplatCameraControllerTests: XCTestCase {
    /// Mirrors the controller's private `walkSpeedMetersPerSecond`.
    private let walkSpeedMetersPerSecond: Float = 1.6
    private let epsilon: Float = 0.0005

    func testDiagonalInputIsRadiallyClampedNotPerAxis() {
        let camera = SplatCameraController()
        camera.mode = .firstPerson
        camera.lookYaw = 0
        let start = camera.position
        camera.moveInput = SIMD2<Float>(1, 1) // diagonal joystick corner
        camera.tick(deltaTime: 0.1)

        let distance = simd_length(camera.position - start)
        // A per-axis clamp lets diagonal input reach walkSpeed*sqrt(2)*dt;
        // a correct radial clamp caps the total magnitude to walkSpeed*dt.
        XCTAssertEqual(distance, walkSpeedMetersPerSecond * 0.1, accuracy: epsilon)
    }

    func testSubThresholdInputIsTreatedAsADeadZone() {
        let camera = SplatCameraController()
        camera.mode = .firstPerson
        camera.moveInput = SIMD2<Float>(0.05, 0) // below the 0.1 dead zone
        let start = camera.position
        camera.tick(deltaTime: 0.1)
        XCTAssertEqual(camera.position, start)
    }

    func testDeltaTimeIsCappedSoAStalledFrameDoesNotTeleport() {
        let camera = SplatCameraController()
        camera.mode = .firstPerson
        camera.lookYaw = 0
        let start = camera.position
        camera.moveInput = SIMD2<Float>(0, 1) // pure forward
        camera.tick(deltaTime: 8.0) // a stalled/backgrounded frame

        let distance = simd_length(camera.position - start)
        XCTAssertEqual(distance, walkSpeedMetersPerSecond * 0.1, accuracy: epsilon)
    }

    func testManySmallTicksMatchOneBigTickOfTheSameTotalDeltaTime() {
        let a = SplatCameraController()
        a.mode = .firstPerson
        a.lookYaw = 0.4
        a.moveInput = SIMD2<Float>(0.3, 0.7)
        a.tick(deltaTime: 0.05)

        let b = SplatCameraController()
        b.mode = .firstPerson
        b.lookYaw = 0.4
        b.moveInput = SIMD2<Float>(0.3, 0.7)
        for _ in 0..<5 { b.tick(deltaTime: 0.01) }

        XCTAssertEqual(a.position.x, b.position.x, accuracy: epsilon)
        XCTAssertEqual(a.position.y, b.position.y, accuracy: epsilon)
        XCTAssertEqual(a.position.z, b.position.z, accuracy: epsilon)
    }

    func testModeChangeClearsMoveInput() {
        let camera = SplatCameraController()
        camera.mode = .firstPerson
        camera.moveInput = SIMD2<Float>(1, 0)
        camera.mode = .orbit
        XCTAssertEqual(camera.moveInput, .zero)
    }

    func testSettingTheSameModeAgainDoesNotClearMoveInput() {
        let camera = SplatCameraController()
        camera.mode = .firstPerson
        camera.moveInput = SIMD2<Float>(1, 0)
        camera.mode = .firstPerson // no transition
        XCTAssertEqual(camera.moveInput, SIMD2<Float>(1, 0))
    }

    func testOrbitModeTickIsANoOpEvenWithMoveInputSet() {
        let camera = SplatCameraController() // starts in .orbit
        camera.moveInput = SIMD2<Float>(1, 0)
        let start = camera.position
        camera.tick(deltaTime: 0.1)
        XCTAssertEqual(camera.position, start)
    }
}
