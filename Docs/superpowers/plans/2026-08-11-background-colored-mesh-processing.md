# Background Colored-Mesh Processing Implementation Plan

> **For Codex:** Execute this plan in this session using `superpowers:executing-plans` and `develop-with-tdd`. Preserve unrelated work, edit with `apply_patch`, and do not commit, push, or open a PR.

**Date:** 2026-08-11
**Approved design:** `Docs/superpowers/specs/2026-08-11-background-colored-mesh-processing-design.md`

## Outcome

An explicitly started colored-mesh build has one app-owned worker, continues when its viewer closes, and uses iOS 26 continued-processing when the runtime and scheduler admit it. Unsupported or rejected runtimes automatically retain the existing foreground worker and explain that the app must remain open. Measured progress drives the system task and idempotent background-only 50%, completion, and interruption notifications. A versioned atomic derived-state record allows safe relaunch reconciliation without modifying original scan evidence.

## Scope

- Add pure execution-mode, milestone, generation, and recovery rules with focused tests.
- Add an app-level `RoomMeshColoringJobCoordinator` that owns at most one detached coloring worker.
- Add availability-isolated BackgroundTasks and UserNotifications adapters.
- Add a disposable atomic job record outside capture bundles.
- Inject the coordinator above room destinations; viewer disappearance detaches but never cancels.
- Expose truthful queued/background/foreground guidance, active percentage, explicit cancellation, interruption, failure, and retry.
- Add the permitted continued-processing task identifier and documentation/device gates.

## Exclusions and invariants

- No server processing, upload, background GPU entitlement, multiple-job queue, automatic start, fake progress, ETA, or partial atlas checkpointing.
- No capture-tick analysis, encoding, blocking synchronization, notification work, or awaits.
- No JPEG quality/codec or ARKit reconstruction/depth-ordering changes.
- No projection, depth, atlas-quality, cache-v3-format, or renderer-quality changes.
- Original capture evidence remains immutable. Only a disposable state record and the already-authorized atomic derived cache may be written.
- iOS 18 remains the deployment target. Device model strings are never used for capability selection.

## Affected boundaries

- **Pure policy/state:** new `RoomMeshColoringJob.swift` plus focused app tests.
- **Platform adapters:** new `RoomMeshBackgroundProcessing.swift` and `RoomMeshColoringNotifications.swift`; iOS 26 APIs remain inside availability guards.
- **Persistence:** new versioned Codable job record/store under Application Support, never inside a capture bundle.
- **Composition/lifecycle:** `AppEnvironment`, `RoomScanStudioApp`, `RoomDetailView`, `RoomMeshViewer`, and the existing progress model/controller boundary.
- **Delivery configuration:** `Resources/Info.plist` and Xcode project membership.
- **Documentation:** real-device test plan, release checklist, and verification log.

## Ordered implementation

### Task 1 — Establish pure capability and notification policies

**Files**

- Add: `RoomScanStudio/Features/RoomViewer/RoomMeshColoringJob.swift`
- Add: `RoomScanStudio/RoomScanStudioTests/RoomMeshColoringJobTests.swift`
- Modify: `RoomScanStudio.xcodeproj/project.pbxproj`

**Red tests**

1. iOS 18–25/unsupported, registration failure, and rejected submission resolve to `.foregroundOnly`; accepted and queued iOS 26 requests resolve to continued processing.
2. A 50% notification decision occurs only on the first below-0.50 to at-least-0.50 accepted progress transition while inactive; crossing while active consumes the milestone without scheduling it later.
3. Completion and interruption decisions occur once, only while inactive; denied authorization cannot affect worker state.
4. Lower-sequence and wrong-generation progress/results are rejected.

Run each focused test and record the intended compile/assertion failure. Implement the smallest pure types and policies, rerun green, then safely mutate the 0.50/background/generation guards one at a time to prove each oracle fails before restoring it. Run all job-policy tests.

### Task 2 — Add atomic derived job-state persistence and recovery policy

**Files**

- Modify: `RoomMeshColoringJob.swift`
- Modify: `RoomMeshColoringJobTests.swift`

**Red tests**

1. Versioned record round-trips atomically with project, generation, mode/state, accepted progress, timestamps, safe failure category, and milestone flags.
2. Corrupt or unsupported-version records are ignored.
3. A valid matching v3 cache wins over stale running state; running/queued without a delivered task becomes interrupted; failed remains retryable.
4. State writes use a temporary sibling and replacement/rename, leaving no accepted partial record.

Implement a file-system-injected store and a pure reconciliation function. Mutate the valid-cache precedence and version check to prove the focused tests detect both guards, restore, and rerun the persistence/recovery group.

### Task 3 — Build the single-job coordinator test-first

**Files**

- Modify: `RoomMeshColoringJob.swift`
- Modify: `RoomMeshColoringProgress.swift`
- Modify: `RoomMeshColoringJobTests.swift`

**Red tests**

1. Repeated starts and same-project reattachment create exactly one worker; another project receives a conflict without queuing work.
2. Detach/view disappearance leaves work running; explicit cancel and scheduler expiration cancel it.
3. Measured progress is monotonic, stale-generation callbacks are ignored, and cache-ready is published only after the loader returns its atomically published result.
4. Continued-task completion follows cache-ready, while renderer-ready remains a separate foreground boundary.
5. Submission rejection starts exactly one foreground fallback worker; notification failure/denial never fails coloring.

Implement an `@MainActor` observable coordinator with injected worker, background adapter, notification adapter, activity-state provider, record store, and cache validator. Keep cooperative cancellation through the existing detached task and generation fence. Safely mutate detach/cancel, single-worker, and publication-order guards, prove focused red, restore, and run the surrounding mesh progress/viewer controller tests.

### Task 4 — Implement availability-isolated platform adapters

**Files**

- Add: `RoomScanStudio/Infrastructure/Background/RoomMeshBackgroundProcessing.swift`
- Add: `RoomScanStudio/Infrastructure/Background/RoomMeshColoringNotifications.swift`
- Modify: `RoomScanStudio/Resources/Info.plist`
- Modify: `RoomScanStudio.xcodeproj/project.pbxproj`
- Modify: `RoomMeshColoringJobTests.swift`

**Changes**

1. Register and submit a queued `BGContinuedProcessingTaskRequest` only from the explicit start path on iOS 26+.
2. Bridge scheduler launch, monotonic `Progress`, phase/title updates, system expiration, explicit cancellation, and exactly-once completion through an availability-neutral protocol.
3. Request notification authorization only for the first supported user-start flow; treat denial/provisional/scheduling errors as non-blocking.
4. Schedule generation-scoped 50%, ready, and interrupted local notifications and remove pending generation identifiers on explicit cancel.
5. Add the permitted identifier to Info.plist; request no GPU resources or entitlement.

Compile focused app tests and an iOS 18-deployment generic-device build. Inspect the current Xcode SDK declarations before writing the adapter so signatures are not guessed.

### Task 5 — Integrate app ownership, navigation, and truthful UI

**Files**

- Modify: `RoomScanStudio/App/AppEnvironment.swift`
- Modify: `RoomScanStudio/App/RoomScanStudioApp.swift`
- Modify: `RoomScanStudio/Features/RoomLibrary/RoomDetailView.swift`
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshColoringProgress.swift`
- Modify: existing/new app and UI tests as needed

**Red tests**

1. Closing the viewer does not cancel the shared worker; reopening the same room attaches to its current percentage/result.
2. Detail/viewer copy distinguishes queued continued processing, usable background processing, foreground-only guidance, interrupted retry, failure, cache-ready, and renderer preparation.
3. Explicit cancellation is available and terminal; retry starts a new generation.
4. An active different-room job is surfaced rather than silently replaced.

Create the coordinator once in app composition and inject it into destinations. Remove lifecycle cancellation from `RoomMeshViewer.onDisappear`; keep Metal preparation foreground-only. Show active job/percentage on room detail and have notification routing identify the project for attachment where the app’s navigation architecture permits deterministic local routing. Add accessibility identifiers for the new status and controls. Run focused app/UI tests.

### Task 6 — Relaunch reconciliation and graceful fallback

**Files**

- Modify: `AppEnvironment.swift`, `RoomMeshColoringJob.swift`, related tests and UI

**Red tests**

1. Launch with a valid matching v3 cache exposes cache-ready.
2. Launch with stale queued/running state and no delivered task exposes interrupted/Retry without starting automatically.
3. Failed state preserves only user-safe failure messaging; missing/corrupt state is ignored.
4. Expiration cannot publish a cache-ready state or success completion for a cancelled generation.

Wire launch reconciliation without automatic processing. Prove expiration/publication generation fences with a safe mutation, restore, and run all coordinator/loader tests.

### Task 7 — Documentation and full verification

**Files**

- Modify: `Docs/real-device-test-plan.md`
- Modify: `Docs/release-checklist.md`
- Modify: `Docs/verification-log.md`

Document that simulator/local builds cannot prove scheduler admission, sustained background execution, system Live Activity behavior, notification timing, force-quit behavior, thermal/battery performance, ARKit registration, scan health, or photo-level quality. Add the iOS 26 LiDAR physical-device matrix from the approved design and the iOS 18–25 fallback check.

Invoke `superpowers:verification-before-completion`, then gather fresh evidence:

1. Focused red/green/mutation logs for every new correctness guard.
2. All background job/coordinator/viewer app tests.
3. Complete RoomScanCore suite.
4. Complete RoomScanStudio app and UI tests on iOS Simulator.
5. Generic iOS device build with signing disabled and iOS 18 deployment compatibility.
6. Built-product inspection for the continued-task identifier, coordinator/notification symbols, textured shader, and v3 cache symbols.
7. `git diff --check`, scoped diff review, and `git status --short` confirming no unrelated changes were overwritten.

## Rollback strategy

Remove the app-level coordinator, platform adapters, notification/persistence record, UI injection, and permitted identifier; restore viewer-owned foreground loading. The v3 cache and capture-bundle schemas are unchanged, so rollback needs no data migration. Existing derived caches remain valid and the disposable job record may be ignored or deleted. Original evidence is never part of rollback.

## Risks and mitigations

- **Scheduler/API availability:** isolate iOS 26 symbols and resolve rejected/unsupported states to the tested foreground worker.
- **Duplicate expensive workers:** one app coordinator plus same-project attach and generation fencing.
- **Late callbacks after cancellation:** generation checks on progress, result, scheduler, and notification callbacks.
- **False 100%:** background success only after loader/cache publication; viewer/Metal completion stays separate.
- **Notification spam:** persisted generation-scoped milestone flags and background-only decisions.
- **Record corruption or stale state:** versioning, atomic replacement, cache-authoritative recovery, and no automatic relaunch work.
- **Memory/thermal pressure:** one job, existing bounded streamed analysis, system-managed priority, and cooperative expiration cancellation.
- **Capture regression:** no capture-path edits; verify capture-sensitive diff and surrounding tests.

## Exact completion oracles

The implementation is locally complete only when every focused test has observed its intended pre-fix/mutated failure and restored pass; all RoomScanCore, RoomScanStudio app, UI, simulator, and generic-device commands pass freshly; the built product contains the required background/notification/cache/shader identifiers; configuration contains no background GPU request; and final diff/status inspection shows only authorized work. Production background continuity and quality claims remain explicitly gated on the physical-device procedure.
