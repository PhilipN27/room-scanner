# Colored-Mesh Progress and Error UX Design

Date: 2026-08-11
Status: Approved interaction design; awaiting written-spec review

## Outcome

RoomScanStudio will replace the indeterminate colored-mesh spinner with a
determinate, monotonic progress display driven by completed pipeline work. The
screen will identify the active phase, show completed and total items when
available, surface a nonfatal warning after 30 seconds without measurable
progress, support cooperative cancellation and retry, and distinguish terminal
failures from recoverable fallbacks.

The percentage describes completed pipeline work. It is not an estimated time
remaining and will never advance from a timer alone.

## Scope

- Add a testable progress model and reporter to the post-capture colored-mesh
  derivation pipeline.
- Instrument source validation, cache inspection, frame analysis, projection
  and visibility, photometric calibration, fallback coloring, face assignment,
  charting and packing, atlas rasterization, padding, encoding, cache
  publication, and renderer preparation.
- Replace the loading spinner with a determinate percentage bar, phase label,
  completed/total detail, and elapsed time.
- Warn after 30 seconds without a new measurable progress event while allowing
  processing to continue.
- Add cooperative Cancel and Retry behavior.
- Add structured failure and warning messages with actionable recovery text.
- Preserve vertex-color fallback when atlas-specific work fails safely.

## Exclusions

- No capture-tick work, additional capture encoding, synchronization, or
  awaits.
- No JPEG codec or quality changes.
- No changes to the device-proven scene-reconstruction/scene-depth ordering.
- No background execution after the user leaves the viewer.
- No time-based fake progress, ETA prediction, telemetry upload, or analytics.
- No hard timeout that incorrectly fails a valid large room.
- No mutation of original capture evidence.

## Architecture

### Progress model

`RoomMeshColoringProgress` is an immutable Sendable value containing:

- a monotonically increasing sequence number;
- a stable phase identifier;
- a user-facing phase title;
- completed and total work units for that phase;
- a normalized overall fraction in `0...1`;
- optional detail such as `Frame 18 of 42`;
- the monotonic time at which the event was created.

The model clamps invalid values, prevents percentage regression, and exposes a
rounded integer percentage for display and accessibility.

`RoomMeshColoringPhase` defines the ordered phases and their fixed overall
ranges:

1. Preparing source and checking the cache: 0-3%.
2. Measuring frame sharpness: 3-13%.
3. Projecting, testing visibility, and gathering colors: 13-53%.
4. Photometric normalization and fallback colors: 53-60%.
5. Assigning faces to frames: 60-70%.
6. Constructing and packing charts: 70-78%.
7. Baking the atlas: 78-94%.
8. Filling mip-safe padding: 94-97%.
9. Encoding and publishing the derived cache: 97-99%.
10. Preparing Metal resources: 99-100%.

Fixed phase ranges keep the percentage stable across runs. Progress within a
phase is based only on completed work units:

- frame phases count completed frames;
- vertex/face phases report bounded batches;
- atlas rasterization counts completed clipped raster rows, using a prepass to
  calculate the total row count for selected faces;
- padding counts its initial boundary scan rows and completed dilation passes;
- encoding counts converted atlas rows before the final system encoder call.

Operations that are atomic from the app's perspective advance only when the
operation returns. The bar may remain at the start of such a substep, but it
must not invent intermediate completion.

### Reporting boundary

`RoomMeshBundleLoader.load` accepts an optional Sendable progress sink and
emits events from the detached worker. The sink has no UI dependency. Existing
tests and callers may omit it.

The viewer owns a main-actor load controller. It:

- starts exactly one worker for the current project;
- accepts events in sequence order and ignores stale events from prior runs;
- stores the latest progress and the time it was received;
- cooperatively cancels the worker on Cancel, Retry, project change, or view
  disappearance;
- prevents a cancelled or superseded worker from publishing ready/error state.

The existing `Task.isCancelled` checks remain and new bounded checks are added
between frame, face-batch, chart-batch, raster-row, dilation, and encoding work.

### Stall monitor

A separate main-actor monitor checks the last accepted progress-event time.
After 30 seconds without measurable progress it sets a nonterminal stalled
state containing the last phase and percentage. It does not cancel the worker
or convert the load into failure.

Any later progress event clears the warning automatically. `Keep waiting`
explicitly dismisses the current warning, but it may return after another 30
seconds without progress. `Cancel` requests cooperative cancellation. Retry is
offered after cancellation or terminal failure and starts a fresh generation.

### Result and error model

The load controller distinguishes:

- `loading(progress, warning)`;
- `ready(result, warnings)`;
- `cancelled`;
- `failed(RoomMeshColoringFailure)`.

Terminal failures include:

- capture bundle or source mesh missing;
- unreadable or empty mesh;
- checked allocation-size overflow or allocation failure;
- Metal device, shader, buffer, or texture creation failure.

Recoverable warnings include:

- one or more keyframes could not be decoded;
- the capture manifest is missing or unusable, or no keyframes remain usable,
  so neutral vertex-color fallback is shown;
- LiDAR depth/confidence payload was malformed and RGB fallback was used;
- atlas construction, full-resolution image decode, or PNG encoding failed and
  the corrected vertex-color mesh was used;
- derived-cache publication failed, so the room renders but must recompute on
  the next open.

Warnings preserve a usable result. They do not present the screen as failed.
Every terminal message includes the failed phase and a recommended action.
Underlying implementation details may be logged locally but are not dumped
verbatim into user-facing copy.

## Interface design

While loading, the viewer shows:

- `Coloring scanned mesh`;
- a determinate linear progress bar;
- a large integer percentage;
- the current phase title;
- completed/total detail when meaningful;
- elapsed time;
- a Cancel button.

The existing dark viewer palette and typography are retained. The progress bar
uses the semantic blueprint accent and does not add decorative animation.

The stall warning appears inline without replacing the progress bar:

`No progress for 30 seconds while <phase>. Large rooms can take longer.`

It offers `Keep waiting` and `Cancel`. Cancelled and terminal states offer
`Try again`; terminal states also keep normal navigation available. Ready
results with recoverable warnings show a compact disclosure rather than
blocking the mesh.

Accessibility identifiers cover the progress bar, percentage, phase, detail,
stall warning, Cancel, Retry, terminal error, and ready warning. VoiceOver
announcements are throttled to phase changes and 10-percentage-point crossings
so per-row progress does not become noisy.

## Accuracy and monotonicity rules

- Overall progress starts at 0 and reaches 1 only after Metal resources are
  ready.
- A phase cannot emit outside its assigned range.
- Completed units cannot exceed total units.
- Sequence numbers and percentages never decrease within one generation.
- Cache hits skip derivation phases with explicit completion events and still
  finish through renderer preparation.
- Fallbacks complete the failed optional phase and record a warning; they do
  not leave the percentage stranded.
- Cancellation never reports 100% or publishes a cache manifest.
- A terminal error retains the last valid percentage and phase.

## Testing

Focused tests will prove:

- phase mapping, clamping, monotonicity, and percentage rounding;
- real frame/face/raster work emits the expected completed/total counts;
- cache hits advance monotonically to renderer preparation;
- a 30-second no-event interval produces a warning, not failure;
- a later event clears the warning;
- stale generation events and results are ignored;
- Cancel reaches cooperative checks and prevents cache-manifest publication;
- Retry starts one fresh worker and resets progress;
- atlas failure returns a vertex-colored result plus warning;
- terminal source and renderer failures provide actionable messages;
- accessibility labels and identifiers expose percentage, phase, and actions.

New correctness guards will receive red/green regression tests and safe
mutation controls. Surrounding verification includes the complete
`RoomScanCore` suite, RoomScanStudio app tests, focused Simulator UI behavior,
and an unsigned generic iOS device build.

## Rollback

The progress sink remains optional, so the loader can revert to synchronous
callers without changing derived-cache formats. The UI controller and progress
view can be removed independently. No original bundle data changes, and
cancelled or failed derivations never publish a valid cache manifest.

## Physical-device gate

Simulator tests prove state transitions and deterministic progress accounting,
not real-room pacing. A LiDAR-device run must confirm that progress continues
through a representative large room, cancellation responds promptly between
bounded work units, stall warnings correspond to genuine lack of events, and
recoverable atlas failure renders the vertex-color fallback.
