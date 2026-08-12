# Background Colored-Mesh Processing Design

Date: 2026-08-11
Status: approved interaction and architecture design; awaiting written-spec review

## Outcome

RoomScanStudio will continue a user-started colored-mesh build when the user
switches to another app or locks the phone on iOS 26 and later. The system will
show live progress, and RoomScanStudio will send background-only local
notifications when measured coloring work crosses 50 percent, when the atomic
colored-mesh cache is complete, and when work is interrupted or fails.

The feature adapts from runtime capabilities and scheduler admission. It does
not use a hard-coded phone-model allowlist. On iOS 18 through 25, or when the
system rejects continued processing, the existing foreground worker remains
available with explicit guidance that RoomScanStudio must stay open.

## Platform basis

The selected iOS 26 API is `BGContinuedProcessingTask`, which Apple documents
for explicit user-started work that may take minutes and must continue after
the app enters the background. The task reports progress through the system
interface and supports system cancellation. Apple also documents that the
system may expire the task under resource pressure and cancels it when the user
force-quits the app.

References:

- https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados
- https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask
- https://developer.apple.com/videos/play/wwdc2025/227/
- https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app

`BGProcessingTask` is not the primary mechanism because the system schedules it
opportunistically while the device is idle and may stop it when the user starts
using the device. That does not meet the requirement to color a room while the
user actively works in other apps.

## User initiation

Continued processing always begins from the user's explicit Colored Mesh
action. It never starts automatically from launch, background refresh, capture
completion, a stored preference, or a timer.

The action requests one job for one project. If that project already has a
running job, the UI attaches to it. If a different project is running, the app
shows that one coloring job is already active and offers navigation to its
status or explicit cancellation. It does not queue multiple memory-intensive
room jobs.

## Adaptive capability policy

A pure capability resolver chooses one of these modes:

1. `continuedBackground`: iOS 26 or later, the API is available, task
   registration succeeds, and the scheduler accepts or queues the request.
2. `foregroundOnly`: iOS 18 through 25, registration failure, submission
   rejection, or another unsupported runtime condition.

The resolver uses availability checks and injected scheduler results. It does
not infer support from device names. The deployment target remains iOS 18.

The default continued-task submission strategy is queue. When the scheduler
cannot start immediately, the UI says `Waiting for iPhone to begin background
processing`. If submission is rejected rather than queued, RoomScanStudio
starts the foreground worker and says `Keep RoomScanStudio open to finish
coloring this room`.

Notification authorization is a separate capability. Denied, provisional, or
unavailable notification permission never blocks coloring. The app requests
authorization only in response to the first supported background-coloring
action and does not repeatedly prompt after denial.

No Background GPU Access capability is requested. Image analysis, visibility,
assignment, and atlas production remain CPU work. Metal resource preparation
occurs only when a viewer is in the foreground.

Low Power Mode, thermal state, memory pressure, and scheduling priority remain
under system control. RoomScanStudio reports accurate progress and responds to
expiration instead of maintaining a stale hardware compatibility table.

## Job ownership and component boundaries

### `RoomMeshColoringJobCoordinator`

One app-level, main-actor coordinator owns the active job independently of a
viewer screen. It:

- starts at most one worker;
- registers and submits a continued task when supported;
- starts the foreground fallback when continued processing is unavailable;
- exposes immutable observable job state to any room detail or viewer screen;
- maps existing measured progress into system progress;
- handles explicit cancellation, scheduler expiration, completion, and failure;
- owns notification milestone decisions;
- persists a small atomic recovery record; and
- resolves stored state against the authoritative derived cache at launch.

The coordinator is injected above individual navigation destinations. A view
disappearing only detaches that observer. It does not stop the job.

### `RoomMeshBackgroundTaskAdapter`

An availability-isolated adapter owns BackgroundTasks framework calls so the
coordinator and tests do not depend directly on iOS 26 types. Its interface
covers registration, submission, progress/title updates, expiration, and
completion. The real adapter is compiled with iOS 26 availability guards; test
adapters deterministically accept, queue, reject, expire, or complete work.

The launch handler is registered when the user expresses the intent to start
continued coloring, as supported for continued processing tasks. The actual
worker starts through the accepted task handler so foreground and background
execution cannot accidentally create duplicate workers.

### `RoomMeshColoringNotificationCoordinator`

A small notification boundary reads authorization, requests it only when
allowed by the user-action flow, and sends idempotent local notifications. It
does not own progress or infer completion.

### Persistent job record

The app writes a versioned atomic derived-state record containing:

- schema version;
- project ID and generation UUID;
- mode (`continuedBackground` or `foregroundOnly`);
- state (`queued`, `running`, `interrupted`, `failed`, or `cacheReady`);
- last accepted progress sequence, phase, fraction, and update time;
- whether the 50-percent, completion, and failure notifications were sent; and
- a user-safe failure category when applicable.

The record contains no image bytes, depth, mesh geometry, or original capture
evidence. It is disposable derived state. Original bundle files remain
immutable.

## Progress semantics

The existing progress reporter remains the sole source of measured work.
Neither background execution nor notifications introduce timer-driven fake
progress.

There are two truthful completion boundaries:

1. The background coloring job reaches 100 percent after the v3 mesh, optional
   atlas, and manifest have been atomically published. The cache is then ready
   to view, and the background task can complete successfully.
2. When the user opens the viewer, the app-level display may briefly show its
   existing 99-percent renderer-preparation state. It reaches 100 percent after
   Metal buffers and textures are ready.

The system Live Activity describes the background job, so cache publication is
its 100-percent boundary. The viewer describes readiness to render, so Metal
preparation remains its final boundary. Copy distinguishes `Colored mesh is
ready` from `Preparing the 3D viewer`.

The adapter maps the measured background work into a monotonic `Progress`
instance and updates the task subtitle at phase changes and meaningful
percentage boundaries. Per-row events remain throttled by the existing
reporter.

## Notification contract

Notifications are sent only while RoomScanStudio is not active. Foreground
users already see the progress interface.

Identifiers include the job generation so delivery is idempotent and stale
requests can be removed. Persisted milestone flags prevent duplicates across
view attachment, scene transitions, and process relaunch.

### 50-percent notification

Send once when the accepted measured coloring fraction crosses from below 0.50
to at least 0.50 while the app is backgrounded.

- Title: `Room coloring is halfway done`
- Body: identifies the room and current coloring phase.

If 50 percent is crossed while the app is active, do not send it later merely
because the app subsequently backgrounds.

### Completion notification

Send once after atomic cache publication succeeds while the app is
backgrounded.

- Title: `Colored mesh is ready`
- Body: identifies the room and invites the user to open it.

Tapping the notification opens the corresponding room and attaches the viewer
to the completed cache.

### Failure or interruption notification

Send once when the task expires or fails while the app is backgrounded.

- Title: `Room coloring was interrupted`
- Body: explains that the original scan is safe and asks the user to reopen
  RoomScanStudio to retry.

A force-quit is a documented exception: iOS cancels continued processing
without giving the app a cancellation callback, so RoomScanStudio cannot send
an immediate final notification. It diagnoses the stale job record on the next
launch.

## Lifecycle and recovery

### Navigation and scene changes

`RoomMeshViewer` no longer calls job cancellation from `onDisappear`. It
attaches and detaches from the app coordinator. Explicit Cancel still
increments the job generation, cancels the worker and background task, clears
pending milestone notifications, and prevents cache-manifest publication.

When the app returns to the foreground, the same worker continues and its
priority remains system-managed. The UI attaches to the latest persisted and
in-memory state without restarting work.

### Expiration and resource pressure

The background task expiration handler immediately flips a thread-safe
cancellation signal and cancels the worker. Existing bounded cancellation
checks stop frame analysis, projection, face batches, chart batches, atlas
rows, dilation, and encoding. The adapter calls `setTaskCompleted(success:
false)` after the worker has observed cancellation or returned failure.

No partial manifest is accepted because the v3 manifest remains the last
atomic publication step. Partial derived assets are disposable.

### Relaunch

At launch, the coordinator reconciles any record with the cache:

- valid matching v3 cache: publish `cacheReady` regardless of a stale stored
  running state;
- queued or running record without a valid cache and without a delivered task:
  publish `interrupted` with Retry;
- failed record: preserve its safe message and Retry;
- missing or corrupt record: ignore it and use normal cache discovery.

The first version does not persist partial frame analysis or atlas checkpoints.
An interrupted job restarts from source evidence. This keeps deterministic
cache construction and atomicity intact.

## Foreground interface

The existing progress screen remains the primary in-app interface. It adds a
compact execution-mode message:

- `You can use other apps while RoomScanStudio colors this room.`
- `Waiting for iPhone to begin background processing.`
- `Keep RoomScanStudio open to finish coloring this room.`

Room detail shows the active job and its percentage even when the viewer is
closed. Opening the colored-mesh viewer attaches to the same coordinator.

Cancellation remains explicit and available in both foreground UI and the
system's continued-task interface. Retry appears only after interruption or
failure. Errors never imply that original capture evidence was lost.

## Failure handling

- Registration or submission rejection: start foreground fallback and explain
  the limitation; do not fail the coloring job.
- Notification denial or scheduling failure: continue coloring without
  notifications.
- Background expiration or system cancellation: cooperatively cancel, mark
  interrupted, and retain original evidence.
- Worker failure: retain the existing vertex/neutral fallbacks where safe;
  terminal failure produces Retry and a background-only failure notification.
- Cache publication failure: the in-memory result remains viewable while the
  app is foregrounded, but the background task does not claim durable
  completion; mark interrupted or failed according to the existing warning
  contract.
- Metal failure: handled only in the foreground viewer and does not invalidate
  a successfully published colored cache.

## Capture safety

This feature changes only post-capture derived processing. It adds no analysis,
encoding, synchronization, awaits, or notification work to the capture tick.
JPEG quality and codec remain unchanged. The device-proven scene
reconstruction/scene-depth ordering remains unchanged.

## Testing strategy

### Focused red-green oracles

- Capability resolver selects foreground-only for iOS 18 through 25 and
  continued processing for accepted or queued iOS 26 requests.
- Registration or submission rejection produces foreground fallback rather
  than failure or duplicate work.
- One coordinator starts exactly one worker across repeated actions,
  navigation, and view reattachment.
- Viewer disappearance does not cancel; explicit Cancel and task expiration do.
- Background progress stays monotonic and reaches its completion boundary only
  after successful cache publication.
- Renderer completion remains a separate foreground boundary.
- The 50-percent notification fires only on the first below-to-above crossing
  while backgrounded.
- Completion fires only after atomic manifest publication.
- Failure/interruption fires once; foreground and denied-authorization paths
  produce no notification.
- Generation IDs reject late progress, results, and notification callbacks.
- Relaunch reconciliation handles valid cache, stale running record, failed
  record, and corrupt record.
- Expiration prevents partial cache-manifest acceptance.

New correctness guards receive safe mutation controls where practical.

### Surrounding local verification

- Complete RoomScanCore suite.
- Relevant RoomScanStudio coordinator, loader, notification, and viewer tests.
- Full iOS Simulator app and UI suites.
- Availability compilation against the iOS 18 deployment target.
- Generic iOS device build with signing disabled.
- Built-product inspection for background-task identifiers, coordinator and
  notification symbols, textured shader, and v3 cache symbols.
- Final diff and repository-status inspection.

### Physical-device gates

Run on one supported iOS 26 LiDAR iPhone before claiming the feature works in
production:

1. Start coloring explicitly, background the app, use two other apps, lock and
   unlock the phone, and confirm measured work continues.
2. Confirm the system Live Activity tracks the app's phase and progress and can
   cancel the job.
3. Confirm exactly one 50-percent and one completion notification while
   backgrounded; confirm neither appears while foregrounded.
4. Deny notification permission and confirm coloring still completes without
   repeated prompts.
5. Force scheduler expiration and verify interruption, cooperative cleanup,
   no valid partial manifest, and Retry on reopen.
6. Force-quit from the app switcher and verify the job stops and stale state is
   diagnosed on next launch. Do not expect an immediate failure notification.
7. Measure foreground versus background elapsed time, peak memory, battery use,
   and thermal state on the same uncached large-room bundle.
8. Verify an unsupported iOS 18-through-25 device or configuration receives
   foreground guidance and never attempts the iOS 26 API.

Simulator tests cannot prove scheduler admission, sustained background CPU
runtime, Live Activity behavior, notification timing, force-quit semantics,
battery impact, or thermal behavior.

## Rollback

The existing synchronous loader and foreground worker remain the functional
fallback. Removing the app coordinator, BackgroundTasks adapter, notification
adapter, permitted task identifier, and job-state record restores the current
foreground-only behavior. The v3 cache and original bundle formats do not
change, so rollback requires no migration and loses no capture evidence.

## Exclusions

- Server-side processing or scan upload.
- Background GPU access.
- More than one concurrent room-coloring job.
- Automatic jobs without an explicit user action.
- Fake time-based progress or ETA prediction.
- Resumable partial analysis or atlas checkpoints in the first version.
- Changes to capture recording, JPEG encoding, ARKit configuration, projection
  accuracy, depth tolerances, atlas resolution, or rendering quality.
