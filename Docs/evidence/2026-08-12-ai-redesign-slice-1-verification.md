# AI redesign platform Slice 1 verification

- Date: 2026-08-12
- Branch: `agent/ai-redesign-platform-plan`
- Baseline HEAD retained: `362c8cd862f38b1d159647d901ba75c6ef749efd`
- Scope: Slice 1 only — spatial truth, orientation, semantics, and property
  containers
- Claim boundary: local implementation and Simulator evidence complete;
  physical LiDAR iPhone/iPad acceptance pending

## Outcome and ownership

`RoomScanCore` owns portable, provider-neutral truth: additive v2 orientation
and redesign documents, the standalone property container, canonical JSON and
digests, validation, deterministic canonical-camera generation, exact
revision/coordinate-epoch binding, semantic tokens, companion persistence, and
the future export/publication readiness guard.

The iOS app owns evidence collection and interaction: first finite scan-start
pose capture, RoomPlan door/opening category adaptation, app-owned suggestion,
explicit confirmation/correction and manual reference-wall fallback, local
property grouping, and semantic presentation. No RoomPlan canonical-entry API
is claimed or invented.

The migration is additive. `roomscan-local-redesign-extension-v2` and
`roomscan-property-container-v1` are canonical companion documents stored in
separate local roots. Existing package/revision files are read to derive exact
bindings and are never rewritten. The strict v1 decoder remains supported.

## Implemented files and contracts

Portable implementation and tests:

- `RoomScanCore/Sources/RoomScanCore/RoomSpatialTruth.swift`
- `RoomScanCore/Sources/RoomScanCore/LocalRoomRedesignStore.swift`
- `RoomScanCore/Sources/RoomScanCore/RoomRedesignContracts.swift` (additive v2
  validator/document case; v1 retained)
- `RoomScanCore/Sources/RoomScanCore/LocalRoomProjectStore.swift` (read-only
  exact revision/digest/epoch binding support)
- `RoomScanCore/Tests/RoomScanCoreTests/RoomSpatialTruthTests.swift`
- `RoomScanCore/Tests/RoomScanCoreTests/RoomRedesignCompanionStoreTests.swift`

iOS integration and tests:

- `RoomScanStudio/App/AppEnvironment.swift`
- `RoomScanStudio/App/AppTheme.swift`
- `RoomScanStudio/Infrastructure/Persistence/RoomLibraryController.swift`
- `RoomScanStudio/Features/RoomCapture/RoomCaptureCoordinator.swift`
- `RoomScanStudio/Infrastructure/Capture/RoomCaptureDependencies.swift`
- `RoomScanStudio/Infrastructure/Capture/AppleRoomCaptureDriver.swift`
- `RoomScanStudio/Infrastructure/Capture/SimulatedRoomCaptureDriver.swift`
- `RoomScanStudio/Features/RoomLibrary/RoomDetailView.swift`
- `RoomScanStudio/Features/RoomViewer/RoomViewerView.swift`
- `RoomScanStudio/Features/RoomViewer/RoomViewerRealityView.swift`
- `RoomScanStudio/RoomScanStudioTests/RoomScanStudioTests.swift`
- `RoomScanStudio/RoomScanStudioUITests/RoomScanStudioUITests.swift`
- `Scripts/select_simulators.py`
- `Scripts/verify_xcode_scaffold.py`

The canonical cameras are exactly entry, wall, corner, orbit, perspective, and
top-down. Orientation accepts only finite, non-degenerate entry vectors,
orthonormal right-handed axes, valid cameras, and matching revision/epoch
bindings. Redesign intent requires free-form text once ready, with optional
structured constraints, Stage/Renovate/Reimagine scope, and independent
per-feature preserve/mayChange/requestedChange permissions. Concept metadata
cannot contain or overwrite captured geometry, measurements, evidence, or
lineage. Property containers contain only independent project membership.

## Red-green and mutation proof

The Slice 1 Core tests were introduced before their production APIs and first
failed to compile. After the initial implementation, the canonical-camera
golden test also failed against its placeholder and pinned the observed stable
digest:
`46c43c43604edf57dc8c35dc20ec8cef461ca9f3ce2b8249838d8ed733937edb`.

Focused restored result: 8 `RoomSpatialTruthTests` plus 4
`RoomRedesignCompanionStoreTests`, 12 tests and 0 failures. They cover finite
validation, degenerate axes/directions/cameras, exact revision/epoch rebinding,
canonical round-trip/digest stability, immutable original revision bytes,
legacy fixture decoding, property non-inference, intent/geometry separation,
Concept Set truth boundaries, suggestion ineligibility, and all nine semantic
roles.

Mandatory live-guard mutation was observed:

1. The exact live guard
   `guard document.orientation.source != .suggested` was temporarily replaced
   with `guard true`.
2. `testOrientationSuggestionUsesAppOwnedEvidenceButNeverBecomesReady` failed
   for the intended reason: `XCTAssertThrowsError failed: did not throw an
   error`.
3. The live guard was restored at `RoomSpatialTruth.swift:703`.
4. All 8 surrounding spatial-truth tests passed.

An earlier screenshot artifact was blank in dark/default mode and was rejected
during visual critique. The UI test now samples the center of each frame and
fails unless actual room pixels have rendered before retaining the attachment.
The restored iPhone and iPad four-variant tests each passed 1/1.

## Local verification

- Complete `RoomScanCore`: 217 tests, 0 failures.
- Focused Slice 1 Core: 12 tests, 0 failures.
- Focused Slice 1 app-unit coverage: simulated suggestion/all semantic roles,
  distinct non-color semantic presentation, and separate companion roots;
  3 tests, 0 failures.
- Focused orientation/property/semantic UI flow: 1 test, 0 failures.
- Focused screenshot matrix: iPhone 1/1 and iPad 1/1, each exercising four
  variants and the nonblank-frame oracle.
- Package resolution: local `RoomScanCore`, MetalSplatter `2b965de`, spz-swift
  `2.1.0`, and swift-argument-parser `1.8.2`.
- Canonical camera/document digests and old-package bytes are covered by the
  restored Core suite.

Fresh isolated full-scheme results:

- iPhone 16 Pro / iOS 26.3.1 Simulator: 123 app tests plus 27 UI
  tests, 150 total and 0 failures;
  `/private/tmp/RoomScanStudio-Slice1-iPhone-isolated-final-20260812-1855.xcresult`.
- iPad (10th generation) / iOS 26.3.1 Simulator: 123 app tests plus
  27 UI tests, 150 total and 0 failures;
  `/private/tmp/RoomScanStudio-Slice1-iPad-isolated-final-20260812-1911.xcresult`.
- Unsigned generic iOS device build: succeeded with
  `CODE_SIGNING_ALLOWED=NO`. The package graph resolved local `RoomScanCore`,
  MetalSplatter `2b965de`, spz-swift `2.1.0`, and
  swift-argument-parser `1.8.2`.
- Delivery inspection: the arm64 iOS build Swift file lists and object output
  contain `RoomSpatialTruth`, `LocalRoomRedesignStore`, `RoomDetailView`,
  `AppleRoomCaptureDriver`, and `RoomViewerView`; the built `RoomScanCore.o`
  contains both v2 schema strings plus `RoomOrientationReadiness`, canonical
  camera, and local redesign-store symbols.
- Static verifier with its hosted-client and weakened-guard mutation controls,
  simulator-selector self-test, and `git diff --check`: passed. The complete
  app-unit suite includes the executable guest launch/capture/save/load/edit/
  legacy-export offline oracle; the structural guard confirms no HTTP, auth,
  or hosted dependency entered the production guest graph.

A concurrent full-scheme attempt was invalidated after simulator resource
contention produced UI timeouts. It is not counted. The two clean results above
were run sequentially and are the final matrix.

## Screenshot matrix and critique

Retained files live in
`Docs/evidence/2026-08-12-ai-redesign-slice-1-screenshots/`:

| Form factor | Appearance | Dynamic Type | SHA-256 |
| --- | --- | --- | --- |
| iPhone | light | default | `ccbe9494b1dacb0e002eeb1750839955bb5bbce9bd5dde609de96cee5d992375` |
| iPhone | dark | default | `ccbe9494b1dacb0e002eeb1750839955bb5bbce9bd5dde609de96cee5d992375` |
| iPhone | light | accessibility XXXL | `5490d335d70e102415b067614b53b1526810f952f7ad6874ecb594481493c9a1` |
| iPhone | dark | accessibility XXXL | `5490d335d70e102415b067614b53b1526810f952f7ad6874ecb594481493c9a1` |
| iPad | light | default | `19d6d204016592d0f24b39a2d9b5b71bfbe63eef50ce0c7faa7391775f6b3ff9` |
| iPad | dark | default | `19d6d204016592d0f24b39a2d9b5b71bfbe63eef50ce0c7faa7391775f6b3ff9` |
| iPad | light | accessibility XXXL | `68988b3120a8feb22203ec6ac473f3bae90b5aa899141ecdcae7d679352d6f1f` |
| iPad | dark | accessibility XXXL | `35e81208b1d9fa6a8ba003210c28b65abd503c7e6bf559db75a68763f2cb214d` |

The viewer is an intentional fixed-dark instrument surface, so light/dark
default captures are identical. Inspection confirms all nine roles are visible
at once, with unique symbols, names, border/pattern treatments, colors,
selection chips, and accessibility descriptions. Color is not the only cue.
Accessibility text remains legible; selection and camera controls preserve
their size in explicit horizontal scrollers instead of shrinking or colliding.

## Physical evidence and rollback

`xcrun devicectl list devices` found one iPhone 17 Pro in `unavailable` state
and no iPad. Therefore no physical claim is made for RoomPlan category quality,
scan-start pose, real door/opening suggestion quality, portrait/landscape AR
conventions, manual correction on hardware, capture cleanup, or LiDAR behavior.
The exact two-device acceptance protocol is recorded in
`Docs/real-device-test-plan.md`.

### In-progress iPhone evidence, 2026-08-12

The iPhone 17 Pro later became available on iOS 26.5.2. A retained real-room
package contained 9 RoomPlan structural elements (4 walls, 1 floor, 2 doors,
and 2 windows) and 6 objects. The first correct Slice 1 device build rendered
the full semantic scene, but doors/windows visibly flickered or disappeared at
some angles. Package inspection proved those zero-depth features shared their
parent walls' plane and the viewer had assigned both the same 25 mm display
depth.

A renderer-only correction projects door/window/opening display boxes beyond
both wall faces and uses an opaque depth pass; it does not modify saved
geometry, measurements, transforms, or revision bytes. Its focused regression
test failed for door, window, and opening when equal-depth behavior was
temporarily restored, then passed after restoring the correction. The complete
app-unit target passed 124/124 and an unsigned generic iOS build succeeded.
The user then orbited the corrected real room and reported the behavior
"flawless"; the provided oblique screenshot shows cleanly separated embedded
door faces without the prior depth-fighting artifacts. This closes the iPhone
semantic coplanar-feature retest only. A fresh Slice 1 capture is still needed
for scan-start orientation evidence, and the complete iPad protocol remains
pending.

### Orientation-preview parity correction, 2026-08-13

A fresh iPhone 17 Pro capture began one step inside the room entrance, centered,
facing inward, with the phone held at chest/neck height. RoomPlan produced four
walls, one floor, two doors, two windows, and four app-presented objects. The
app-owned review suggested `Door 1 of 2` at 85% confidence and kept Save
disabled until the required free-form redesign request was present. The device
screenshots proved that door numbering, correction selection, semantic labels,
per-feature permissions, and the not-ready-until-confirmed disclosure were
present. They also exposed a display defect: the orientation-plan preview used
`+Z` upward while the semantic viewer displayed `+Z` downward, vertically
reflecting the room and furniture.

The correction makes the default plan use the semantic viewer's display
convention and adds display-only **Rotate 90°**, **Mirror**, and **Reset view**
controls. The same transform is applied to every plan polygon, numbered entry
marker, selection, and inward arrow. An optional
`RoomTopDownPresentationTransform` persists clockwise quarter turns and
horizontal mirroring in the local redesign companion. It cannot change entry
position/direction, canonical axes/cameras, feature IDs, captured geometry,
measurements, evidence, lineage, coordinate epoch, or immutable revision bytes.
Manual facing choices are converted from the displayed direction back into the
unchanged room coordinate space before save.

Red-green proof and final local evidence for this correction:

- the Core test initially failed to compile before the presentation contract
  existed; the app parity test initially failed to compile before the pure
  display transform existed;
- the focused app transform test passes and proves `+Z` renders downward,
  rotate/mirror move every feature together, stable feature IDs survive, and
  displayed manual directions invert back to world coordinates;
- the strengthened orientation/property/semantic UI flow passes on iPhone and
  iPad, including Rotate `90 degrees`, Mirror `On`, Save, reopen, persisted
  values, enabled Reset, property grouping, and all nine semantic roles;
- complete Core: 220/220; complete app-unit target: 126/126;
- complete iPhone 16 Pro / iOS 26.3.1 Simulator scheme: 153/153,
  `/private/tmp/roomscanstudio-slice1-ipad-focused-rerun-derived/Logs/Test/Test-RoomScanStudio-2026.08.13_02-14-59--0400.xcresult`;
- complete iPad (10th generation) / iOS 26.3.1 Simulator scheme: 153/153,
  `/private/tmp/roomscanstudio-slice1-ipad-focused-rerun-derived/Logs/Test/Test-RoomScanStudio-2026.08.13_02-00-35--0400.xcresult`;
- exact package resolution, unsigned generic iOS build, and built-artifact
  symbol inspection succeeded; `git diff --check` passed;
- neutralizing the live suggested-orientation readiness guard made its focused
  negative test fail because no error was thrown; restoring it made the same
  test and all 11 surrounding spatial-truth tests pass;
- the static verifier's weakened-guard and injected-HTTP controls passed. Its
  ordinary invocation currently reports only the intentionally local,
  uncommitted `DEVELOPMENT_TEAM` used for physical-device installation.

The device screenshots are defect-discovery evidence, not acceptance evidence
for the correction. The corrected default parity, all four rotations, mirror,
reset, persistence, and unchanged semantic viewer still require a fresh iPhone
retest. The full protocol remains required on a supported LiDAR iPad. No Slice
2 work began.

Rollback is local and byte-safe: disable/remove the new review/property/viewer
UI and ignore/remove the separate redesign/property companion roots. Legacy
packages and immutable revision bytes need no migration or rollback. No server,
portal, upload, authentication, account, billing, CloudKit-sync repurposing,
credential, production configuration, or other external system changed. No
files were staged or committed.

Slice 1 is locally implemented but is not genuinely complete end to end until
the supported physical LiDAR iPhone and LiDAR iPad gate passes. Slice 2 was not
started. This got no cross-model pass.
