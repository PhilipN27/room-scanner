# UI overhaul design spec — Home, Room Profile, Room Viewer

Status: council round 3 (Claude ↔ Codex gpt-5.6-sol). Requirements locked by
Philip 2026-08-11; visual direction delegated to the council. Round-2 REVISE
findings integrated below (walk-mode action gating, shared Metal camera
hardening, thumbnail generator/display scope, hero cache identity+boundary).

## Design principles

1. **Evolve the field-instrument identity, don't replace it.** Keep the
   adaptive paper/instrument split in `AppPalette`, the serif/mono/rounded
   type roles, cyan-for-information / amber-for-acquisition accents.
2. **Data-honest drafting language.** Hairline rules, tick marks, and rail
   labels appear only when they carry real values (revision count, renderer
   kind, capture date, measured bounds, capability state). No faux sheet
   numbers, no decorative ticks.
3. **Hierarchy over uniformity.** One primary action per screen region;
   everything else visibly subordinate. No screen renders >4 peer pills.
4. **Real geometry everywhere imagery appears.** The fake rectangle-pattern
   thumbnail dies at BOTH ends (round-2 finding): the capture drivers'
   `writeProjectThumbnail` is replaced to draw the real
   `RoomFloorPlanProjection` (so new captures store real geometry), and
   every display site — profile hero, home Rooms surface, AND
   `ExistingRoomsView` library rows — derives its preview from the
   hero/floor-plan pipeline computed from the package payload, so legacy
   packages with stored pattern PNGs never surface them. Never the fake
   pattern, anywhere.
5. **Calm motion.** 120–200 ms ease-out / critically damped transitions;
   springs only where physical continuity exists (joystick thumb return).
   Respect Reduce Motion (snap instead of interpolate).
6. **Both appearances, all sizes.** Adaptive colors on paper surfaces, fixed
   instrument colors on renderer surfaces; no fixed heights; Dynamic Type
   through accessibility sizes; 44 pt targets; VoiceOver labels on all
   icon-only controls.

## Component family (new, in AppTheme.swift or adjacent)

- `InstrumentButtonStyle` with roles: `.primary`, `.secondary`, `.quiet`,
  `.destructive` — replaces ad-hoc .bordered/.borderedProminent tints.
- `RoomHeroMedia` — states: snapshot image / floor-plan fallback / loading /
  failure. 4:3, fixed graphite surface, works in both appearances.
- `StatusRail` — compact mono rail of real facts (renderer kind, revision
  count, availability), horizontal, wraps at accessibility sizes.
- `MetadataDisclosure` — expandable info section (the "i" affordance).
- `ViewerChrome` — safe-area-aware overlay chrome for full-screen viewers.

## Home (HomeView.swift)

Top-to-bottom:
1. Narrow top rail: `ROOM / FIELD` kicker left, capability status chip +
   settings gear right. Capability chip is compact (icon + one word),
   expands detail on tap — the real-capture vs deterministic-fixture
   distinction must stay discoverable.
2. **Rooms** surface (library): dominant, shows an actual cached room image
   (hero snapshot of most recent room; floor-plan fallback) + "N rooms"
   count + chevron. Tap → Existing Rooms. Requires moving library refresh
   up into HomeView (today only ExistingRoomsView refreshes — stale-count
   bug otherwise).
3. **Scan a room** surface: amber acquisition accent, viewfinder symbol,
   one-line capability summary, no paragraph. Tap → New Room Scan.
4. Two-line evidence footer: local-first line + measurements-are-estimates
   line (mono, muted).

The hero headline paragraph is deleted. Compact width: stacked surfaces,
content-driven heights. Regular width: asymmetric two-column composition
(Rooms dominant), via ViewThatFits/size-class switch.

## Room profile (RoomDetailView.swift)

Vertical order:
1. `RoomHeroMedia` hero, front and center.
2. `StatusRail`: renderer kind (`SEMANTIC` / `COLORED MESH` / `PHOTOREAL`),
   revision count, capture date.
3. Room name (editorial serif) + location line if recorded + "i" Info button
   (labeled, accessible) toggling the `MetadataDisclosure`.
4. Primary action: **Open room** — opens the best available renderer
   (photoreal splat > colored mesh > semantic boxes). When alternatives
   exist, a compact labeled renderer chooser sits beside/below it.
5. Secondary row (`.secondary` role): Edit room, Rescan, Duplicate.
6. `MetadataDisclosure` (collapsed by default): captured, last revised,
   manual location, GPS, notes, tags; **Edit metadata** in its header.
   Thumbnail path and head-revision id move to a copyable technical-details
   subsection under Manage — they are diagnostics, not profile content.
7. Immutable revision timeline: real timeline rule (drafting language,
   data-honest), head revision clearly marked; links to revision inspect.
8. **Manage** disclosure (collapsed): Archive/Unarchive, Export head
   revision, Export capture bundle, Back up full project, Import/Replace
   photoreal splat, technical details, and Delete permanently
   (`.destructive`, separated at the bottom).

## Room viewer (RoomViewerView.swift — semantic; pattern shared with mesh/splat screens)

Presentation: `fullScreenCover` (not sheet), no inner NavigationStack —
custom `ViewerChrome` overlay on a full-bleed renderer that ignores safe
areas (chrome respects them).

- Top leading: labeled Close control (chevron + "Close").
- Top center: **Orbit | Walk** switcher (two modes only; Pan is two-finger
  drag inside Orbit, matching the Metal viewers, not a peer mode).
- Top trailing: **Layers** button → popover/tray with Structure, Objects,
  Measurements, Annotations, Photos toggles.
- Orbit mode: compact bottom tray — Reset, Top, Front, Side.
- Walk mode: joystick bottom-leading (safe-area-inset positioned, no
  hard-coded offsets), look-drag on remaining surface; accessible
  directional alternatives (adjustable action / directional buttons) for
  VoiceOver and switch control.
- Selection: bottom drawer for the selected semantic item (not a permanent
  list); quiet renderer disclosure `SEMANTIC BOXES / NOT SURVEY GEOMETRY`.
- Chrome never fully auto-hides; may dim after inactivity. Mode switches
  crossfade controls 150–200 ms; camera presets interpolate (snap under
  Reduce Motion).
- Fix existing bug: selecting a mode must also set the gesture input
  interpretation (today "First person" leaves inputMode on orbit).

## Camera reducer contract (RoomScanCore/RoomViewerEditor.swift)

New action: `move(localX: Double, localZ: Double, deltaTime: Double)`.
- Walk mode moves ONLY through `.move`: `.pan` and `.zoom` are orbit-only
  and return the camera unchanged in first person (round-2 finding — the
  previous pitch-following first-person zoom changed eye height). The
  magnification gesture is not attached in walk mode.
- Transient joystick vector stays in the view layer; NOT stored in the
  Codable `RoomViewerCamera`.
- Guards: finite inputs; radial clamp of (localX, localZ) magnitude to 1
  (per-axis clamping allows √2 diagonal speed — bug in existing splat
  joystick, fix there too); dead zone; deltaTime capped (e.g. ≤ 100 ms) so
  stalls don't teleport; yaw-only forward/right vectors (walk, not fly);
  eye-height held constant in walk (no vertical drift).
- View drives it from a display-linked tick while joystick is engaged;
  input cleared on gesture end, mode change, disappear, scene deactivation.
- Unit tests: frame-rate independence (N small ticks == one big tick of
  same total dt within epsilon), diagonal normalization, invalid input
  rejection, delta cap, orbit-only pan/zoom, mode-transition input clearing.

### Shared Metal camera hardening (explicit scope, viewer slice)

`SplatCameraController` + `SplatWalkJoystick` (used by both splat and
colored-mesh viewers) get the same guarantees: radial input clamp (replacing
the per-axis clamp), dead zone, monotonic-clock deltaTime capped at 100 ms
(replacing uncapped Date diffs), and `moveInput` cleared on mode change,
view disappear, and scene deactivation in BOTH viewer screens. App-layer
unit tests (RoomScanStudioTests) cover: tick math clamp/cap, and input
clearing on mode change / disappear / scenePhase deactivation.

## Hero snapshot pipeline (new, RoomScanStudio + reuse RoomMeshViewer pieces)

- Offscreen Metal render of the colored mesh: offscreen color+depth
  textures, deterministic framing from mesh bounds (isometric-ish 3/4 view),
  command-buffer completion before readback, BGRA→RGBA + flip, sRGB-correct,
  size capped near display need (~800 px wide @2x class).
- Async only: profile shows floor-plan projection immediately, crossfades to
  mesh snapshot when ready. Never blocks on RoomMeshBundleLoader.load.
- Cached as DERIVED data (not capture evidence), keyed by the ENTIRE
  upstream colored-mesh cache manifest plus rendered-asset hashes
  (colored PLY SHA256 + atlas SHA256) + hero algorithm version + pixel
  class + sRGB tag (round-2 finding: source-input keys alone go stale when
  the derived colorization changes). Implemented:
  `RoomMeshHeroCache`/`RoomMeshHeroCacheManifest` in Core, tested.
- Stored OUTSIDE the capture bundle, in package-root `derived/`, accessed
  ONLY through store-owned, root-lock-protected APIs (round-3 finding: UI
  and renderer code never observe or write package URLs in this
  architecture). Implemented + tested: `LocalRoomProjectStore.heroCache /
  publishHeroCache / invalidateHeroCache` returning
  `RoomMeshHeroCachePayload` (bytes, never URLs); image written before
  manifest so a crash mid-publish fails validation and regenerates.
- Exports filter derived cache files through
  `RoomMeshPhotorealCache.isDerivedCacheFile(_:)` (Core, tested), which
  covers the `scene-mesh-photoreal-*` family AND the legacy
  `scene-mesh-colored.ply` (round-3 finding). The training export re-adds
  the colored mesh EXPLICITLY as the deliberate splat-seed training input
  (preferred `ply_file_path`), so the seed feature is intentional, not an
  enumeration leak; filtered files can never become the seed path by
  accident. Implemented + tested (app-layer export test: photoreal cache
  excluded, seed present and preferred).
- Deterministic framing: `RoomMeshHeroFraming.make(boundsMin:boundsMax:
  aspectRatio:)` in Core (tested — bounding-sphere fit in the limiting FOV,
  3/4 azimuth/elevation, degenerate-bounds safe).
- Floor-plan display fallback: appearance-aware rendering built from the
  same pure `RoomFloorPlanProjection` (don't reuse the cream export bitmap
  verbatim unless the paper-drawing look is deliberate — decide in
  implementation with both appearances screenshot-verified).

## Implementation routing (Claude-side; Codex reviews)

- Mechanical SwiftUI slices — Claude Sonnet subagents: AppTheme component
  family; HomeView restyle; RoomDetailView reorganization; viewer chrome +
  fullScreenCover migration; accessibility/Dynamic Type passes.
- Contract/rendering slices — Claude main session: reducer `move` action +
  tests; display-link integration with RealityKit; offscreen Metal snapshot
  pipeline + cache; joystick gesture coexistence.
- Adversarial review — Codex gpt-5.6-sol: this spec (round 2), then
  /break-it on the implementation diff with real test output.
- Physical-device gates (Philip's iPhone): simultaneous joystick+look-drag
  touch handling; RoomPlan capture unaffected; Metal snapshot on-device.

## Verification

- RoomScanCore reducer tests (new move-action suite) + existing suites pass.
- Simulator screenshots: all three screens, light+dark, compact+regular,
  an accessibility text size, portrait+landscape for the viewer.
- Build green; no new warnings. Then /break-it on the full diff.
