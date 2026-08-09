import ARKit
import RoomPlan

enum DeviceCapabilityRequirement: String, Equatable {
    case roomPlanCapture = "Room capture"
    case sceneMesh = "LiDAR scene mesh"
}

enum DeviceSupportStatus: Equatable {
    /// RoomPlan support is the only gate for a live capture attempt. Mesh
    /// reconstruction is optional evidence capability, never a reason to
    /// suppress supported RoomPlan capture.
    case captureAvailable(sceneMeshAvailable: Bool)
    case fixtureMode(missing: [DeviceCapabilityRequirement])

    var canStartLiveCapture: Bool {
        if case .captureAvailable = self {
            return true
        }
        return false
    }

    var sceneMeshAvailable: Bool {
        if case let .captureAvailable(sceneMeshAvailable) = self {
            return sceneMeshAvailable
        }
        return false
    }

    var title: String {
        switch self {
        case .captureAvailable:
            return "RoomPlan capture available"
        case .fixtureMode:
            return "Fixture mode"
        }
    }

    var detail: String {
        switch self {
        case let .captureAvailable(sceneMeshAvailable):
            if sceneMeshAvailable {
                return "RoomPlan reports live capture support. Scene mesh is available only as an optional evidence probe on a physical device."
            }
            return "RoomPlan reports live capture support. Scene mesh is unavailable, so raw-mesh evidence is omitted without blocking capture."
        case let .fixtureMode(missing):
            let capabilityList = missing.map(\.rawValue).joined(separator: " and ")
            return "\(capabilityList) is unavailable here. You can inspect the deterministic MockRoom-v1 fixture instead of starting a camera session."
        }
    }
}

protocol DeviceCapabilityProviding {
    var roomCaptureSupported: Bool { get }
    var sceneMeshSupported: Bool { get }
}

extension DeviceCapabilityProviding {
    var supportStatus: DeviceSupportStatus {
        if !roomCaptureSupported {
            return .fixtureMode(missing: [.roomPlanCapture])
        }
        return .captureAvailable(sceneMeshAvailable: sceneMeshSupported)
    }
}

struct SystemDeviceCapabilityProvider: DeviceCapabilityProviding {
    var roomCaptureSupported: Bool {
        RoomCaptureSession.isSupported
    }

    var sceneMeshSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}

struct FixtureDeviceCapabilityProvider: DeviceCapabilityProviding {
    let roomCaptureSupported: Bool
    let sceneMeshSupported: Bool
}
