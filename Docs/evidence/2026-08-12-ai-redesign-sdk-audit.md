# AI redesign installed-SDK feasibility audit

- Date: 2026-08-12
- Host: Xcode 26.3, build 17C529
- SDK: iPhoneOS 26.2
- Compile target: `arm64-apple-ios18.0`
- Scope: API existence and availability only; no physical-device behavior is
  inferred from headers or type-checking

## Mechanical evidence

The following read-only commands identified the active toolchain:

```text
xcode-select -p
/Applications/Xcode.app/Contents/Developer

xcodebuild -version
Xcode 26.3
Build version 17C529

xcrun --sdk iphoneos --show-sdk-version
26.2
```

A minimal Swift probe under `/private/tmp` imported `ARKit`, `RoomPlan`,
`LocalAuthentication`, and `UIKit`, touched the APIs described below, and was
type-checked with:

```sh
xcrun swiftc \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk \
  -target arm64-apple-ios18.0 \
  -typecheck /private/tmp/apple_sdk_probe.swift
```

The probe exited 0. `ARSession.captureHighResolutionFrame()` imported as
`async throws`; the installed header declares the completion API available
from iOS 16. The isolated source comment was reconciled to that declaration;
the comment itself is not used as availability evidence.

## RoomPlan

The installed `RoomPlan.swiftinterface` establishes:

- `CapturedRoom` has walls, doors, windows, openings, objects, and an
  identifier from iOS 16; floors, sections, story, and version are available
  from iOS 17.
- Surfaces expose category, classification confidence, dimensions, transform,
  identifier, and optional curve. The SDK categories cover wall, opening,
  window, door, and floor at the documented availability.
- Objects expose category, confidence, dimensions, transform, identifier, and
  documented categories including storage, appliances, bed, plumbing
  fixtures, table, sofa, chair, fireplace, television, and stairs.
- `RoomCaptureSession` exposes support detection, run/stop, configuration and
  delegate callbacks; `RoomBuilder` converts `CapturedRoomData` asynchronously.
- `RoomCaptureView` exposes its capture session, and its explicit-AR-session
  initializer is available from iOS 17.

Searching the complete installed RoomPlan Swift interface for entry and
orientation produces no entry-orientation API. Therefore the approved
canonical entry position and inward direction are app-owned derived data. A
suggestion may use scan-start pose and door/opening geometry, but AI export or
publication must require user confirmation or the approved manual reference-
wall fallback.

The current production path is real source, not a proposed API:

- `AppleRoomCaptureDriver` owns one `RoomCaptureView`, uses that view's one
  `RoomCaptureSession` and `ARSession`, receives full `CapturedRoom` updates,
  and processes the final `CapturedRoomData`.
- `AppleRoomPlanSnapshotAdapter` maps the installed surface/object fields into
  the portable semantic model.

No header or Simulator result proves RoomPlan support or output on a particular
device. A supported LiDAR iPhone and iPad remain required release gates.

## ARKit camera, depth, and mesh

The installed ARKit headers establish:

- `ARCamera.transform` is the camera pose in world coordinates.
- `ARCamera.intrinsics` is the 3-by-3 calibration matrix and
  `imageResolution` defines its pixel reference. Orientation-aware projection,
  unprojection, view, and display transforms are public APIs.
- `ARFrame` exposes camera, captured image, timestamp, anchors, optional scene
  depth, optional smoothed scene depth, and EXIF data at their documented
  availabilities.
- `ARConfiguration.FrameSemantics` includes scene depth and smoothed scene
  depth. Callers must check `supportsFrameSemantics` before enabling them.
- `ARWorldTrackingConfiguration` exposes scene-reconstruction support and
  configuration. Reconstructed geometry arrives as `ARMeshAnchor` with
  vertices, normals, faces, and optional face classification.
- `ARDepthData.depthMap` is per-pixel depth in meters and has an optional
  confidence map.

The current capture-bundle recorder reads the same retained AR session's
current frame, requires normal tracking, and records pose, intrinsics,
resolution, captured image, optional depth/confidence, and EXIF metadata.
Scene reconstruction and frame semantics are guarded by SDK support checks.

Only supported physical devices can prove pose/orientation conventions,
RoomPlan/mesh co-existence, actual depth/confidence formats, availability,
performance, thermal behavior, and the repository's observed two-phase
mesh-then-depth behavior.

## LocalAuthentication

The installed LocalAuthentication headers establish:

- `.deviceOwnerAuthenticationWithBiometrics` is biometric-only.
- `.deviceOwnerAuthentication` uses biometry when available and permits device
  passcode fallback. It fails when no device passcode is configured.
- `canEvaluatePolicy` is only an immediate preflight and its result is not
  guaranteed after the app backgrounds.
- `evaluatePolicy` is asynchronous. Its completion arrives on an unspecified
  private queue, so application state must be updated on the appropriate actor.
- `NSFaceIDUsageDescription` is required when Face ID is used. The current
  `Info.plist` intentionally has no such entry because Slice 0 adds no Face ID
  execution path.
- On iOS 18, `domainState.biometry.stateHash` replaces the deprecated evaluated
  policy domain state. It can detect local enrollment change; it is not user
  identity, server authentication, or biometric material.
- Biometric unlock reuse does not mean a previous in-app or cross-app biometric
  result is reused. Sensitive-action policy must be explicit.

Real Face ID hardware must prove success, failure, cancellation, lockout,
passcode fallback, backgrounding, and enrollment-state behavior. The Simulator
and this type-check do not close that gate.

## Share Sheet

The installed UIKit header establishes that `UIActivityViewController` has a
completion-with-items handler carrying optional activity type, a `completed`
flag, optional returned items, and optional error. The handler is cleared after
the activity performs or the controller is dismissed. UIKit does not promise a
completion queue, so state updates must cross to the application actor.

The existing export path already treats success and cancellation as idempotent
lease-cleanup outcomes and configures the popover source view/rectangle for
iPad. The SDK does not promise that a nil activity type uniquely means cancel,
nor does it prove behavior of Files, AirDrop, or third-party applications.
Physical iPhone and iPad tests remain required for completion, cancellation,
error, dismissal fallback, and cleanup claims.

## Slice 0 conclusion

All required API families exist in the installed SDK and type-check at the
current app deployment target. The one missing supposed capability is
intentional: RoomPlan has no canonical-entry/orientation record, so the
approved app-owned and user-confirmed contract is required. Slice 0 introduces
no hardware path and makes no physical-device claim.
