# Real-device test plan

## Purpose

These tests are pending physical evidence on one supported LiDAR iPhone and
one supported LiDAR iPad. They are not satisfied by the deterministic fixture
or Simulator driver.

1. Verify `RoomCaptureSession.isSupported` gates live capture. Verify optional
   scene reconstruction only controls the raw-mesh omission status, never the
   RoomPlan capture gate.
2. Confirm **Prepare capture** is the first camera-permission trigger and
   **Request GPS** is the first location-permission trigger. Denial must leave
   manual location usable and create no package until explicit Save.
3. Inspect the black semantic canvas, one injected app-owned ARSession, Stop
   privacy behavior, processing/retry/discard cleanup, reference-photo quality,
   and the RoomPlan raw/processed/USDZ evidence byte closure.
4. Exercise viewer and editor on saved data at default and accessibility Dynamic
   Type sizes, including no-clip disclosure, save/cancel, and stale-head error.
5. Test a CloudKit development container only after explicit opt-in and a
   deliberate Back up action. Confirm local use remains functional when iCloud
   is unavailable or disabled.

Production V1 rescan remains unavailable: no continuous registration survives
the privacy stop and no ARWorldMap is requested. Fixture-only rescan is not
device evidence.

## Pending photoreal colored-mesh gates

Run all six gates below on a supported LiDAR device before enabling a
photo-quality release claim. Record device model, OS/app build, bundle ID,
lighting, frame/depth yield, and the derived-cache manifest with each result.

1. Compare the pipeline's raw-sensor projection with
   `ARCamera.projectPoint` at the image center, all four edges, rotated camera
   poses, and portrait-held scanning. The maximum disagreement is **0.5 source
   pixel**. Simulator fixtures do not satisfy this registration gate.
2. Capture a checkerboard or equivalent high-contrast target and inspect the
   atlas against the JPEGs for any consistent horizontal or vertical color
   offset. Retain the source image and matching viewer screenshot.
3. Capture black, mid-gray, white, and solid-color patches. Confirm the prior
   midtone brightening is absent and record sampled source/viewer values; this
   is the device check for the end-to-end sRGB/linear path.
4. Compare atlas output with source photographs from multiple viewpoints,
   including furniture/wall boundaries and thin occluders. Record both good
   and failed coverage regions rather than reporting a single subjective
   score.
5. Run matched scans with the previous and redesigned capture recorders.
   Confirm normal scan completion and healthy, growing mesh-anchor and
   depth-bearing-keyframe counts; record frame yield, bundle size, CPU
   pressure, thermal state, and scan duration. Verify scene reconstruction is
   enabled first, mesh anchors appear, and scene depth is enabled only after
   that observed anchor gate.
6. On the minimum supported LiDAR device, measure peak memory and elapsed time
   during first-open 1024px analysis/full-resolution atlas generation. Cancel
   during frame analysis and chart baking, confirm the UI remains responsive,
   and confirm no partial v3 manifest is accepted afterward. For the same
   uncached large-room bundle, record vertex/face/keyframe counts and elapsed
   time at the displayed sharpness, projection, normalization, assignment,
   atlas, padding, and publication phase boundaries. Compare the optimized
   build with the preceding build using the same source evidence; do not infer
   device speedup from host-only timing tests.

Status: **pending physical-device evidence**. Local Core/Xcode tests cannot
prove ARKit subpixel registration, scan-health performance, thermal behavior,
or photo-level appearance.

## Pending iOS 26 background-coloring gates

Run these on one supported iOS 26 LiDAR iPhone with an uncached large-room
bundle. Simulator success does not prove scheduler admission, sustained
background CPU time, the system Live Activity, notification timing, resource
expiration, force-quit behavior, battery use, or thermal behavior.

1. Explicitly start Colored Mesh, switch between at least two other apps, lock
   and unlock the phone, and confirm measured phase/percentage work continues.
2. Confirm the system continued-processing UI follows the measured percentage,
   reaches 100% only after the v3 cache manifest is atomically published, and
   can cancel the job without accepting a partial manifest.
3. While RoomScanStudio is backgrounded, confirm exactly one 50% notification
   and one ready notification. Repeat entirely in the foreground and confirm
   neither notification appears.
4. Deny notification permission. Confirm coloring continues, no repeated
   permission prompt appears, and the in-app progress/error UI remains usable.
5. Exercise system expiration/resource pressure. Confirm cooperative
   cancellation, one interruption notification when callback delivery is
   available, original evidence safety, and Retry after reopening.
6. Remove RoomScanStudio from the app switcher. Confirm iOS cancels queued or
   active continued processing and the next launch diagnoses the stale record;
   do not expect an immediate notification because iOS supplies no callback.
7. Compare foreground and background elapsed time, peak memory, battery, and
   thermal state using the same bundle and build. Retain the phase log.
8. On iOS 18 through 25 (or a deliberately rejected scheduler submission),
   confirm the app uses foreground-only mode, never invokes an unavailable
   iOS 26 API, and clearly says RoomScanStudio must remain open.

Status: **pending physical-device evidence**. The local availability build and
injected scheduler tests prove fallback selection and wiring, not operating
system runtime guarantees.

## Pending named field test: Norwalk YMCA Computer Lab

Run this separately on the chosen LiDAR iPhone and LiDAR iPad. Record device
model, OS build, app build, room lighting, scan path, and any permission or
tracking interruption. Review whether the semantic result interprets two
six-station desk groups, the podium, and the centered back/right entry in a
useful way. Check table/chair treatment as movable-object classifications
without encoding those expectations in app logic. Compare displayed estimates
with independently recorded reference measurements and retain the two device
evidence sets separately. This is a pending field-test plan, not a claim that
the room or classifications have been validated.
