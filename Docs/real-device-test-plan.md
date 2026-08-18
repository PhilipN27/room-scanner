# Real-device test plan

## Purpose

These tests are not satisfied by the deterministic fixture or Simulator
driver. The owner has accepted Slice 1 orientation behavior and Slice 2 quality
behavior on a supported LiDAR iPhone; the Slice 2 acceptance is based on direct
observation, and only three screenshots were retained, not a complete
independent artifact/device-metadata matrix. The owner does not currently have
an iPad and has waived physical iPad acceptance for the present development
program; all physical-iPad behavior remains explicitly unverified.
Device-dependent protocols continue to document the evidence required for
claims that have not yet been observed and for any future independently
auditable rerun.

1. Verify `RoomCaptureSession.isSupported` gates live capture. Verify optional
   scene reconstruction only controls the raw-mesh omission status, never the
   RoomPlan capture gate.
2. Confirm **Prepare capture** is the first camera-permission trigger and
   **Request GPS** is the first location-permission trigger. Denial must leave
   manual location usable and create no package until explicit Save.
3. Inspect the black semantic canvas, the single `RoomCaptureView`-owned
   ARSession/RoomCaptureSession chain, Stop privacy behavior,
   processing/retry/discard cleanup, reference-photo quality, and the RoomPlan
   raw/processed/USDZ evidence byte closure.
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

## Pending AI redesign platform device gates

These gates apply in the later slices that implement the named behavior. The
Slice 0 installed-SDK type-check proves API declarations only and cannot satisfy
any item below.

1. On a supported LiDAR iPhone, capture representative doors,
   openings, windows, walls, floors, and objects. Compare the saved portable
   categories/transforms/dimensions with the live RoomPlan result. Exercise the
   app-owned entry suggestion from scan-start pose and doorway/opening geometry,
   then prove the user can confirm or replace it with the manual reference-wall
   fallback before AI export or publication.
2. On that device, record known camera poses and targets in portrait and
   landscape. Prove the chosen world/camera convention, intrinsics and image-
   resolution interpretation, display transform, canonical camera projections,
   supported mesh reconstruction, depth/confidence formats, poor-tracking
   behavior, two-phase mesh-then-depth configuration, cancellation, and final
   session cleanup. Retain source evidence and expected-vs-observed values.
3. On real Face ID/passcode hardware, exercise success, user/system cancel,
   authentication failure, biometric lockout, passcode fallback, no-passcode
   state, background/foreground transitions, enrollment/domain-state change,
   and MainActor UI handoff. Confirm no biometric material or domain-state value
   is treated as server identity.
4. On physical iPhone, share to Files, AirDrop, and one external app.
   Exercise success, cancellation, activity error, interactive dismissal, and
   fallback cleanup. Confirm the temporary export lease is released exactly
   once and that an optional/nil activity type is not used as stronger evidence
   than UIKit provides.

Status: **Slice 1 local implementation complete; corrected physical-iPhone
orientation behavior owner-accepted.** Later-slice Face ID and Share Sheet
behavior is not implemented. Other unobserved device behavior remains open.
Physical iPad is owner-waived and unverified. Simulator, unit-test, header, and
successful-build results do not close physical gates.

### Slice 1 spatial truth acceptance

Run this protocol on one supported LiDAR iPhone. Record device model, OS/build,
app build, room, lighting, device
orientation, and any tracking interruption. Retain each room-project package,
the app-owned suggestion inputs, screenshots, and the resulting local spatial
extension.

1. Begin each scan from a measured pose and capture rooms with (a) one clear
   door, (b) multiple doors/openings, and (c) no clear entrance. Compare the
   recorded first finite scan-start transform and saved portable RoomPlan
   door/opening categories, dimensions, and transforms with the visible room.
2. For (a) and (b), inspect the suggested entry position, inward direction,
   evidence label, and confidence before confirmation. Prove it remains
   `suggested` and fails orientation readiness until an explicit user confirm
   or correction. Do not interpret the suggestion as a RoomPlan canonical
   entry.
3. For (c), select a reference wall and facing direction manually. Confirm the
   saved orientation is `manual`, points inward in the normalized room, binds
   the exact immutable revision and coordinate epoch, and passes readiness.
4. For every case, reopen the project and compare entry, wall, corner, orbit,
   perspective, and top-down camera records byte-for-byte with the first saved
   extension. Before saving, compare the default top-down plan with the semantic
   viewer: doors, windows, walls, and furniture must have the same handedness
   and relative placement. Exercise Rotate 90° through all four positions,
   Mirror/Unmirror, and Reset view. Confirm every feature, numbered marker,
   selection, and inward arrow moves together; no feature changes identity;
   Reset restores viewer parity. Save a rotated+mirrored presentation, reopen,
   and confirm the display preference persists while entry position/direction,
   axes, cameras, captured geometry, measurements, evidence, lineage, revision
   bytes, and coordinate epoch remain unchanged. Confirm portrait/landscape
   presentation does not mutate those authoritative values.
5. Exercise cancel, capture failure, retry, discard, save failure, and a normal
   save. Confirm the capture session/AR session and scan-start state are cleaned
   up; no companion state is published before the room revision commits; a
   companion-write failure does not rewrite or corrupt the committed package.
6. Inspect walls, doors, windows, openings, floor, ceiling, fixed objects,
   movable objects, and unknown objects in the saved viewer at default and
   accessibility Dynamic Type in light and dark mode. Confirm symbol, label,
   pattern/border, selection treatment, and accessibility description—not color
   alone—distinguish every role.
7. Group two independently captured rooms into one property, remove one, and
   reopen. Confirm only stable project membership is stored and no transform,
   alignment, doorway connectivity, shared coordinates, or property geometry
   is inferred or displayed.

The owner accepted corrected Slice 1 orientation behavior on the physical
LiDAR iPhone. Physical-iPad acceptance is waived for the current development
program and remains unverified, not passed or failed. Any future iPad run must
retain its own evidence set and must not be inferred from Simulator evidence.

## Slice 2 live and finish-time quality acceptance

Run the following controlled protocol on one supported LiDAR iPhone. Record the
device model and OS/build, app build, room and lighting, scan path, tracking
interruptions, posed-keyframe/evidence counts, expected affected physical
region, displayed overlay/revisit guidance, Finish summary, saved immutable
quality report, and reopen/persistence result for each case.

1. Capture a well-lit, sharp, acceptably covered room as the good control.
   Confirm normal Finish and no fabricated warning or region.
2. Introduce deliberate motion blur while viewing one known wall/region.
   Confirm only visual-sharpness guidance identifies that qualitative region
   and unaffected dimensions remain independent.
3. Deliberately omit one wall/region. Confirm coverage guidance identifies the
   missed area without claiming unsupported precision.
4. Cause a controlled tracking interruption near a known region, then recover.
   Confirm tracking guidance is separate from sharpness and coverage.
5. Occlude or ambiguously present a feature. Confirm semantic-identification
   guidance names the uncertain feature/region only when evidence supports it.
6. Produce one scan with multiple independent defects. Confirm the structured
   Finish review retains each dimension, exact reason codes, evidence, and
   region bindings rather than collapsing them into one score.
7. Choose Revisit and Cancel in separate weak attempts. Confirm neither path
   publishes a partial quality report. Then complete a weak attempt, choose
   explicit Save Anyway, reopen it, and compare the persisted report,
   acknowledgement, project/revision/epoch bindings, reason codes, evidence,
   and affected regions with the Finish review.

Use good and bad controls for each case. A future independently auditable run
requires the displayed region to correspond to the deliberately affected
physical location, unaffected dimensions to remain independent, the advisory
gate never to reject or delete the scan, and the original revision bytes never
to be rewritten. Simulator and installed-SDK evidence cannot supply that
physical evidence.

Status (reconciled 2026-08-16): **owner-accepted on the physical LiDAR iPhone
based on direct observation.** Only three physical-run screenshots were
retained; they are not a complete independent artifact/device-metadata matrix
for the seven cases above. The generic `regions` label and repeated tracking
guidance remain known limitations. Keep this protocol for any future retained,
independently auditable rerun; do not reinterpret owner acceptance as a full
artifact matrix.

The owner has waived the physical-iPad Slice 2 protocol. Continue the complete
iPad Simulator scheme, but record physical-iPad behavior as unverified and make
no physical-iPad claim.

## Slice 3 AI Room Package and Concept Set acceptance

Run this protocol on a supported LiDAR iPhone after the final local Slice 3
matrix is recorded. Retain device model, OS/build, app build, source
project/revision/coordinate-space epoch, exact package profile, test asset
hashes, and the Share Sheet/import target for every case. Do not use provider
output quality as an oracle and do not upload a real room unless the owner has
made a separate informed decision.

1. Start with a validated source revision with confirmed/manual orientation,
   a nonempty redesign request, and a quality carrier. Build AI-ready, inspect
   the disclosure inventory, exclude/replace a selected image, and confirm the
   prior approval becomes stale before a fresh review. Verify precise GPS,
   world maps, private notes, and raw RGB/depth/confidence are absent.
2. Build Complete only after the exact raw-evidence disclosure approval.
   Change the profile, selection, or source revision after approval and confirm
   sharing is blocked until a new review. Verify Complete still excludes precise
   GPS and world maps.
3. Share a validated package to Files, AirDrop, and one installed external app;
   separately exercise completion, cancellation, error, and sheet dismissal.
   Confirm the temporary archive remains available during activity, cleanup is
   exactly once, and no source package/revision/semantic geometry/evidence is
   deleted or rewritten.
4. Import a known-safe loose JPEG/PNG and a known-safe packaged Concept Set;
   reject malformed, mislabeled, trailing-payload, unsupported, stale, and
   source-rebound controls. Confirm automatic mapping only for exact declared
   canonical views, manual mapping only from current canonical IDs, and
   unmatched otherwise. Archive/delete/reopen must affect only the selected
   Concept Set.
5. Exercise backgrounding and foreground recovery during review, build, share,
   and import. Confirm no pending approval, staging directory, export lease, or
   partial Concept Set becomes shareable/published after cancellation or
   interruption.

Status (2026-08-17): not run because the physical LiDAR iPhone is unavailable.
Physical iPad is owner-waived and remains unverified. Simulator evidence cannot
close this device/system Share Sheet and security-scoped-import protocol.

## Deferred end-of-program field test: Norwalk YMCA Computer Lab

This named example is explicitly deferred until the entire app is complete. It
is not a Slice 2 acceptance requirement and must not block the generic device
protocols above.

Run this separately on the chosen LiDAR iPhone and LiDAR iPad. Record device
model, OS build, app build, room lighting, scan path, and any permission or
tracking interruption. Review whether the semantic result interprets two
six-station desk groups, the podium, and the centered back/right entry in a
useful way. Check table/chair treatment as movable-object classifications
without encoding those expectations in app logic. Compare displayed estimates
with independently recorded reference measurements and retain the two device
evidence sets separately. This is a pending field-test plan, not a claim that
the room or classifications have been validated.
