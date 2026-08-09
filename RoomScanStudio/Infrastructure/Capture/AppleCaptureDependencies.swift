@preconcurrency import AVFoundation
@preconcurrency import CoreLocation
import Foundation
import RoomScanCore

/// Production camera-permission provider. It only requests access after the
/// coordinator has received the user's explicit Prepare action; creating this
/// provider itself has no camera side effect.
@MainActor
final class AppleCameraPermissionProvider: RoomCameraPermissionProviding {
    nonisolated static func capturePermission(
        for status: AVAuthorizationStatus
    ) -> RoomCapturePermission {
        switch status {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .denied
        }
    }

    func requestCameraPermission(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCapturePermission {
        switch Self.capturePermission(
            for: AVCaptureDevice.authorizationStatus(for: .video)
        ) {
        case .authorized, .denied:
            return Self.capturePermission(
                for: AVCaptureDevice.authorizationStatus(for: .video)
            )
        case .unknown:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .authorized : .denied
        }
    }
}

/// Retains one location manager/proxy pair per explicit one-shot request.
/// Permission denial and an unavailable fix are nonfatal because manual
/// location remains available in the review state.
@MainActor
final class AppleLocationProvider: NSObject, RoomLocationProviding {
    /// A fresh manager/proxy pair is retained for exactly one request. This
    /// gives every delegate callback an opaque request identity, so a callback
    /// from a cancelled attempt cannot satisfy a later attempt's continuation.
    private let makeLocationManager: () -> CLLocationManager
    private var locationManager: CLLocationManager?
    private var delegateProxy: AppleLocationDelegateProxy?
    private var continuation: CheckedContinuation<RoomCaptureGPSResult, Never>?
    private var activeAttempt: RoomCaptureAttemptToken?
    private var activeRequestID: UUID?
    private var awaitingLocationFix = false
    private var requestStartedAt: Date?

    init(
        makeLocationManager: @escaping () -> CLLocationManager = { CLLocationManager() }
    ) {
        self.makeLocationManager = makeLocationManager
        super.init()
    }

    nonisolated static func capturePermission(
        for status: CLAuthorizationStatus
    ) -> RoomCapturePermission {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .denied
        }
    }

    nonisolated static func locationServicesResult(
        servicesEnabled: Bool
    ) -> RoomCaptureGPSResult {
        servicesEnabled ? .authorized(nil) : .denied
    }

    /// A cached location predating this one-shot request is deliberately
    /// treated as a completed no-fix result. Returning without resuming would
    /// strand the request continuation and leave Save blocked indefinitely.
    nonisolated static func oneShotResult(
        location: RoomGPSLocation?,
        requestStartedAt: Date?
    ) -> RoomCaptureGPSResult {
        guard
            let location,
            let requestStartedAt,
            location.capturedAt < requestStartedAt
        else {
            return .authorized(location)
        }
        return .authorized(nil)
    }

    func requestCurrentLocation(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCaptureGPSResult {
        guard CLLocationManager.locationServicesEnabled() else {
            return Self.locationServicesResult(servicesEnabled: false)
        }
        guard continuation == nil else {
            // The reducer admits only one request. This defensive return keeps
            // a malformed second caller from starting another location query.
            return .denied
        }

        let manager = makeLocationManager()
        let requestID = UUID()
        let proxy = AppleLocationDelegateProxy(requestID: requestID)
        proxy.owner = self
        manager.delegate = proxy
        locationManager = manager
        delegateProxy = proxy
        activeAttempt = attempt
        activeRequestID = requestID
        awaitingLocationFix = false
        requestStartedAt = Date()

        let permission = Self.capturePermission(for: manager.authorizationStatus)
        switch permission {
        case .denied:
            clearRequestState()
            return .denied
        case .authorized, .unknown:
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                if permission == .authorized {
                    requestOneLocationFixIfNeeded(
                        for: attempt,
                        requestID: requestID
                    )
                } else {
                    manager.requestWhenInUseAuthorization()
                }
            }
        }
    }

    func cancelCurrentLocation(for attempt: RoomCaptureAttemptToken) async {
        guard let requestID = activeRequestID, activeAttempt == attempt else {
            return
        }
        // `requestLocation()` is one-shot, but stopping defensively prevents a
        // manager from carrying an old update stream into the next attempt.
        locationManager?.stopUpdatingLocation()
        finish(.denied, for: attempt, requestID: requestID)
    }

    fileprivate func didChangeAuthorization(
        _ permission: RoomCapturePermission,
        requestID: UUID
    ) {
        guard let attempt = activeAttempt, activeRequestID == requestID else { return }
        switch permission {
        case .authorized:
            requestOneLocationFixIfNeeded(for: attempt, requestID: requestID)
        case .denied:
            finish(.denied, for: attempt, requestID: requestID)
        case .unknown:
            break
        }
    }

    fileprivate func didReceiveLocation(
        _ location: RoomGPSLocation?,
        requestID: UUID
    ) {
        guard
            let attempt = activeAttempt,
            activeRequestID == requestID
        else {
            return
        }
        // Location managers can surface cached fixes. A fix older than the
        // request is not allowed to contaminate a new capture attempt, but it
        // must still resolve the one-shot request as a nonfatal no-fix result.
        finish(
            Self.oneShotResult(location: location, requestStartedAt: requestStartedAt),
            for: attempt,
            requestID: requestID
        )
    }

    fileprivate func didFailLocationRequest(requestID: UUID) {
        guard let attempt = activeAttempt, activeRequestID == requestID else { return }
        // A no-fix result is not a denial and must not block manual metadata.
        finish(.authorized(nil), for: attempt, requestID: requestID)
    }

    private func requestOneLocationFixIfNeeded(
        for attempt: RoomCaptureAttemptToken,
        requestID: UUID
    ) {
        guard
            continuation != nil,
            activeAttempt == attempt,
            activeRequestID == requestID,
            !awaitingLocationFix
        else {
            return
        }
        awaitingLocationFix = true
        locationManager?.requestLocation()
    }

    /// Resumes and clears only the continuation owned by this attempt/request
    /// pair. Stale delegate callbacks are ignored rather than attaching a
    /// coordinate to a later attempt.
    private func finish(
        _ result: RoomCaptureGPSResult,
        for attempt: RoomCaptureAttemptToken,
        requestID: UUID
    ) {
        guard activeAttempt == attempt, activeRequestID == requestID else {
            return
        }
        let pending = continuation
        locationManager?.stopUpdatingLocation()
        clearRequestState()
        pending?.resume(returning: result)
    }

    private func clearRequestState() {
        continuation = nil
        activeAttempt = nil
        activeRequestID = nil
        awaitingLocationFix = false
        requestStartedAt = nil
        delegateProxy?.owner = nil
        delegateProxy = nil
        locationManager = nil
    }
}

/// Core Location delegate callbacks are received outside the coordinator's
/// actor. This tiny proxy converts framework values to Foundation DTOs before
/// hopping back to the provider's main actor.
private final class AppleLocationDelegateProxy: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    weak var owner: AppleLocationProvider?
    private let requestID: UUID

    init(requestID: UUID) {
        self.requestID = requestID
        super.init()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let permission = AppleLocationProvider.capturePermission(
            for: manager.authorizationStatus
        )
        Task { @MainActor [weak owner, requestID] in
            owner?.didChangeAuthorization(permission, requestID: requestID)
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let location = locations.last.flatMap(Self.makeGPSLocation)
        Task { @MainActor [weak owner, requestID] in
            owner?.didReceiveLocation(location, requestID: requestID)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak owner, requestID] in
            owner?.didFailLocationRequest(requestID: requestID)
        }
    }

    private static func makeGPSLocation(_ location: CLLocation) -> RoomGPSLocation? {
        guard
            location.coordinate.latitude.isFinite,
            location.coordinate.longitude.isFinite,
            (-90...90).contains(location.coordinate.latitude),
            (-180...180).contains(location.coordinate.longitude),
            location.horizontalAccuracy.isFinite,
            location.horizontalAccuracy >= 0
        else {
            return nil
        }
        return RoomGPSLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            capturedAt: location.timestamp
        )
    }
}
