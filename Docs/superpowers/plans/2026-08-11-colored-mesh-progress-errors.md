# Colored-Mesh Progress and Error UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Multi-agent execution is intentionally excluded for this tightly coupled change.

**Goal:** Replace the indeterminate colored-mesh spinner with measured, monotonic phase progress, a 30-second nonfatal stall warning, cooperative cancellation/retry, and actionable terminal/recoverable error states.

**Architecture:** Add a UI-independent progress domain and thread-safe reporter, instrument the synchronous detached loader with real work counts, and place a main-actor controller between the worker and SwiftUI. Atlas failure remains recoverable through the corrected vertex-color mesh; source/renderer failures remain terminal. Renderer preparation owns the final 99-100% transition.

**Tech Stack:** Swift 5, SwiftUI, XCTest, Swift concurrency, Foundation locking/continuous time, ImageIO, MetalKit, RoomScanCore.

## Global Constraints

- The percentage describes completed pipeline work. It is not an estimated time remaining and will never advance from a timer alone.
- Warn after 30 seconds without a new measurable progress event while allowing processing to continue.
- No hard timeout that incorrectly fails a valid large room.
- No capture-tick work, additional capture encoding, synchronization, or awaits.
- No JPEG codec or quality changes.
- No changes to the device-proven scene-reconstruction/scene-depth ordering.
- No background execution after the user leaves the viewer.
- No mutation of original capture evidence.
- Cancellation never reports 100% or publishes a cache manifest.
- Preserve unrelated working-tree changes. Use `apply_patch`; do not commit, push, or open a PR.

## Outcome, scope, and exclusions

Outcome is the approved design in `Docs/superpowers/specs/2026-08-11-colored-mesh-progress-errors-design.md`. Scope includes progress accounting, loader instrumentation, controller lifecycle, loading/stall/cancel/retry/error/warning UI, tests, and verification documentation. Derived-cache bytes and algorithm version remain unchanged because progress reporting does not affect output. Capture recording and ARKit configuration are excluded.

## Affected boundaries

- Create `RoomScanStudio/Features/RoomViewer/RoomMeshColoringProgress.swift`: progress phases, values, warning/failure presentation, monotonic reporter, stall tracker, and load controller.
- Modify `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`: loader progress/warnings/cancellation instrumentation, atlas row/padding/encoding counts, cache publication result, screen rendering, and renderer completion.
- Modify `RoomScanCore/Sources/RoomScanCore/RoomMeshTextureBaker.swift`: optional compact-dilation progress and cancellation callbacks without coupling RoomScanCore to app UI types.
- Create `RoomScanStudio/RoomScanStudioTests/RoomMeshColoringProgressTests.swift`: domain, tracker, generation, cancel/retry, and copy contracts.
- Modify `RoomScanStudio/RoomScanStudioTests/RoomMeshViewerAppTests.swift`: end-to-end loader progress, cache hit, warning/fallback, cancellation/publication, and accessibility-source contracts.
- Modify `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshTextureBakerTests.swift`: compact-dilation callback/cancellation regression tests.
- Modify `Docs/verification-log.md`: exact red/green/mutation/build evidence.

## Rollback strategy

The loader progress sink defaults to `nil`, so instrumentation can be removed without changing existing callers or cache formats. The controller and progress view are isolated to the colored-mesh screen. Optional-phase failures continue to produce an in-memory fallback. Atomic cache publication keeps the manifest last; partial derived assets remain invalid without it.

## Risks

- Excessive progress events could overload the main actor. The reporter emits only sequence/phase changes or meaningful percentage/unit thresholds.
- Detached task cancellation does not propagate automatically. The controller must hold and explicitly cancel the worker handle and reject stale-generation events/results.
- A phase weighting bug could regress the percentage. Progress construction and reporter monotonicity receive focused tests and a mutation control.
- PNG encoding and some framework calls are atomic from the app's perspective. The UI must honestly remain at the substep start and use the stall warning rather than fake progress.
- Atlas failure must not discard the usable fallback mesh. End-to-end tests force atlas failure and assert a ready result with warnings.

---

### Task 1: Progress domain and monotonic reporter

**Files:**
- Create: `RoomScanStudio/Features/RoomViewer/RoomMeshColoringProgress.swift`
- Create: `RoomScanStudio/RoomScanStudioTests/RoomMeshColoringProgressTests.swift`

**Interfaces:**
- Produces `RoomMeshColoringPhase: Int, CaseIterable, Sendable` with `title`, `lowerBound`, and `upperBound`.
- Produces `RoomMeshColoringProgress: Equatable, Sendable` with `sequence`, `phase`, `completedUnits`, `totalUnits`, `fraction`, `percent`, and `detail`.
- Produces `RoomMeshProgressReporter` initialized with `(@Sendable (RoomMeshColoringProgress) -> Void)?` and `report(phase:completed:total:detail:)`.
- Produces `RoomMeshColoringWarning` and presentation text for recoverable fallbacks.

- [ ] **Step 1: Write failing phase/progress tests**

Assert exact phase ranges, clamping, integer percentage rounding, cache-skip completion, and that a later report with lower phase/units cannot regress the emitted fraction.

- [ ] **Step 2: Run the focused test and observe missing-type compile failures**

Run:
`xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -destination 'platform=iOS Simulator,id=B8FBE9EA-81AD-4134-BC1D-A67A7747271E' -derivedDataPath /private/tmp/RoomScanStudioDerived test -only-testing:RoomScanStudioTests/RoomMeshColoringProgressTests`

- [ ] **Step 3: Implement the minimum progress domain**

Use the approved ranges 0-3, 3-13, 13-53, 53-60, 60-70, 70-78, 78-94, 94-97, 97-99, and 99-100 percent. Protect reporter sequence and last fraction with `NSLock`; call the sink after releasing the lock.

- [ ] **Step 4: Rerun the focused test green**

- [ ] **Step 5: Temporarily bypass monotonic clamping, prove the regression test fails, restore, and rerun**

### Task 2: Dilation progress and cooperative cancellation

**Files:**
- Modify: `RoomScanCore/Sources/RoomScanCore/RoomMeshTextureBaker.swift`
- Modify: `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshTextureBakerTests.swift`

**Interfaces:**
- Extend `dilateLinearUInt16(..., onProgress: ((Int, Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) -> Bool`.
- Return `false` only when cancelled; preserve identical pixels/owners when it returns `true`.

- [ ] **Step 1: Add focused callback and cancellation tests**

Assert initial boundary rows and completed dilation passes advance monotonically, cancellation returns `false`, and a cancelled call stops before filling all requested padding.

- [ ] **Step 2: Run the tests and confirm signature/behavior failures**

Run: `swift test --filter RoomMeshTextureBakerTests`

- [ ] **Step 3: Add row/pass reporting and bounded cancellation checks**

Use total work `height + iterations`; report completed boundary-scan rows and one unit after each applied dilation pass. Do not copy the full atlas.

- [ ] **Step 4: Rerun texture-baker tests green**

- [ ] **Step 5: Neutralize the cancellation check, prove the focused test fails, restore, and rerun**

### Task 3: Instrument loader work and recoverable fallbacks

**Files:**
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomMeshViewerAppTests.swift`

**Interfaces:**
- Change `RoomMeshBundleLoader.load(forProject:progress:) throws -> RoomMeshColoredResult`, with a default `nil` sink.
- Add `[RoomMeshColoringWarning]` to `RoomMeshColoredResult`.
- Make cache publication return success/failure and keep manifest publication last.
- Make atlas baking throw cancellation while returning recoverable atlas failure separately.

- [ ] **Step 1: Add failing end-to-end loader progress tests**

Capture emitted events for a synthetic bundle. Assert monotonic 0..<0.99 loader progress, exact sharpness/projection frame counts, face-assignment completion, atlas/padding/encoding phases, and cache publication at 99%. Load again and assert cache-hit phases advance monotonically without derivation work.

- [ ] **Step 2: Add failing fallback/warning and cancellation tests**

Force missing keyframes and atlas encode/decode failure; assert a usable vertex-colored result plus warning. Cancel during a progress callback; assert `CancellationError` and absence of `scene-mesh-photoreal-v3.json`.

- [ ] **Step 3: Run focused app tests red**

Run the `RoomMeshViewerAppTests` target with `xcodebuild`.

- [ ] **Step 4: Instrument preparing, frame, normalization, face, chart, atlas, padding, encoding, and cache work**

Emit frame completion after every attempted decode; emit face completion in bounded batches; precompute clipped atlas raster-row totals and report completed rows; translate compact-dilation callbacks into padding progress; report converted RGBA rows before the atomic PNG call.

- [ ] **Step 5: Implement warning collection and cancellation propagation**

Warnings cover unreadable frames, malformed optional depth, absent/unusable manifest, atlas fallback, and cache publication failure. Insert `Task.checkCancellation()` between bounded units and immediately before publishing each derived asset and the manifest.

- [ ] **Step 6: Rerun focused app tests green and run surrounding RoomMesh tests**

### Task 4: Main-actor lifecycle, stall tracker, cancellation, and retry

**Files:**
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshColoringProgress.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomMeshColoringProgressTests.swift`

**Interfaces:**
- Produce `RoomMeshStallTracker` with `accept(progress:at:)`, `evaluate(at:threshold:)`, and `dismiss(at:)`.
- Produce `@MainActor RoomMeshLoadController: ObservableObject` with published progress/result/failure/warnings/stall/cancelled/renderer-ready state and `start`, `cancel`, `retry`, `rendererDidFinish`, and `stop`.
- Worker generations use monotonically increasing IDs; stale events/results are ignored.

- [ ] **Step 1: Add failing stall tests**

Assert 29.999 seconds is not stalled, 30 seconds is stalled without failure, a later progress sequence clears it, and dismissal restarts the 30-second window.

- [ ] **Step 2: Add failing lifecycle tests with an injected worker**

Assert one active worker, explicit cancellation, stale result rejection, retry generation reset, and renderer completion as the only transition to 100%.

- [ ] **Step 3: Run focused tests red**

- [ ] **Step 4: Implement tracker and controller**

The controller explicitly cancels its detached worker from a task cancellation handler. Its one-second monitor uses continuous time and never changes percentage. Cancellation invalidates the generation before changing UI state.

- [ ] **Step 5: Rerun focused tests green**

- [ ] **Step 6: Neutralize stale-generation rejection and prove its test fails, restore, and rerun**

### Task 5: SwiftUI progress, warnings, errors, and recovery actions

**Files:**
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomMeshColoringProgressTests.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomMeshViewerAppTests.swift`

**Interfaces:**
- `RoomMeshViewerScreen` owns `@StateObject RoomMeshLoadController`.
- Accessibility identifiers: `meshViewer.progress`, `meshViewer.percent`, `meshViewer.phase`, `meshViewer.progressDetail`, `meshViewer.stall`, `meshViewer.cancel`, `meshViewer.retry`, `meshViewer.error`, and `meshViewer.warning`.

- [ ] **Step 1: Add failing copy/accessibility contract tests**

Assert determinate progress, phase and percentage copy, 30-second warning copy, Cancel/Keep waiting/Try again actions, warning disclosure, and all identifiers.

- [ ] **Step 2: Run focused tests red**

- [ ] **Step 3: Replace local `LoadState` with controller rendering**

Show percentage, `ProgressView(value:total:)`, phase, detail, elapsed time, and Cancel. Show the inline stall warning without hiding progress. Cancellation/failure show Try again. Create the Metal view when the CPU result arrives but keep the progress overlay through renderer preparation; only renderer success reveals controls and emits 100%.

- [ ] **Step 4: Present recoverable warnings without blocking usable rendering**

Use compact inline disclosure with the warning accessibility identifier. Preserve navigation in every state.

- [ ] **Step 5: Rerun focused app tests green**

### Task 6: Verification and documentation

**Files:**
- Modify: `Docs/verification-log.md`

- [ ] **Step 1: Invoke `superpowers:verification-before-completion`**

- [ ] **Step 2: Run restored focused regression tests and record counts**

- [ ] **Step 3: Run complete `swift test`**

- [ ] **Step 4: Run complete RoomScanStudio app-unit tests in the iOS Simulator**

- [ ] **Step 5: Run the focused Simulator UI contract if an executable route exists; otherwise document the exact physical/manual visual gate**

- [ ] **Step 6: Build for generic iOS device with signing disabled**

Run:
`xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/RoomScanStudioDeviceDerived CODE_SIGNING_ALLOWED=NO build`

- [ ] **Step 7: Inspect built-product symbols and source contracts**

Confirm progress phase strings, stall copy, retry/cancel identifiers, textured shader, and v3 cache symbols are delivered.

- [ ] **Step 8: Run `git diff --check`, inspect the complete diff and untracked files, and confirm capture-ordering source is unchanged**

- [ ] **Step 9: Record successful local evidence and retain the physical LiDAR-device latency/cancellation/peak-memory gate**

## Exact completion oracles

- The initial focused progress tests fail for missing types/behavior, then pass.
- Mutation controls prove monotonicity, cancellation, and stale-generation tests detect their live guards.
- A synthetic uncached bundle emits monotonic measured events through 99%; renderer completion alone emits 100%.
- A cache hit emits monotonic skip/completion events and reaches renderer preparation.
- Thirty seconds without a new event produces a warning while the worker remains active; later progress clears it.
- Cancel prevents ready state and valid cache-manifest publication; Retry starts exactly one fresh generation.
- Atlas-specific failure yields a usable fallback plus warning; missing/unreadable source and Metal failures yield actionable terminal errors.
- Complete RoomScanCore and RoomScanStudio app-unit suites pass.
- Generic unsigned iOS device build succeeds.
- Final diff/status inspection is clean of whitespace errors and contains no commit, push, or PR.
- Physical-device pacing, cancellation responsiveness, and peak memory remain explicitly unproven until tested on a representative LiDAR room.
