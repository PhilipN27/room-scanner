# Release checklist

Status: **Verified on Windows** items below are static only. Checked **macOS
CI** and dated **local Xcode** items are runtime/build evidence; remaining
external and physical-device items stay unchecked until observed.

- [x] Windows static: `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=1`,
  app language mode Swift 5.0, package tools 5.9, 1024px opaque RGB AppIcon
  header, and required-reason privacy manifest contract parsed.
- [x] Windows static: CI workflow pins checkout/upload actions by full SHA,
  discovers iPhone/iPad simulators dynamically, and preserves xcresults.
- [x] Windows static: Dynamic Type source/test contracts, semantic contrast
  calculations, fixed-dark surface roles, and no fixed user-facing font sizes
  passed the structural oracle.
- [x] macOS CI: resolved the local package, passed 122/122 `RoomScanCore`
  tests, and built the unsigned generic iOS application with Xcode 16.4.
- [x] macOS CI: passed 62 app tests plus 25 UI tests on each dynamically
  selected iPhone and iPad Simulator in run 31359458769.
- [x] 2026-08-12 local Xcode baseline-only checkpoint: detached exact-baseline
  worktree plus baseline repairs passed 178 Core tests, 120 app + 25 UI tests
  on both iPhone and iPad Simulators, exact package resolution, and an unsigned
  generic-device build. It contains no AI redesign contract source or object.
- [x] 2026-08-12 local Xcode Slice 0 checkpoint: integrated worktree passed
  205 Core tests, 121 app + 25 UI tests on both iPhone and iPad Simulators,
  exact package resolution, and an unsigned generic-device build with the
  redesign contract object/symbols present.
- [x] 2026-08-12 Slice 0 boundary checkpoint: strict version/kind fixtures,
  raw-default and portal-archive guards, SDK declaration type-check, hosted
  ADR, threat model, and current executable guest capture/save/edit/legacy-
  export offline oracle passed. This does not close any physical or hosted
  gate below.
- [x] 2026-08-12 local Xcode Slice 1 checkpoint: 217 Core tests and isolated
  123 app + 27 UI tests on each iPhone and iPad Simulator passed; exact package
  resolution and unsigned generic-device build succeeded with Slice 1 source,
  schema strings, and readiness/store symbols present in the delivery output.
- [x] 2026-08-12 Slice 1 visual checkpoint: all eight iPhone/iPad
  light/dark/default/accessibility screenshots passed the nonblank oracle and
  visual critique. Nine semantic roles are distinguished by text, symbol,
  border/pattern, selection treatment, accessibility description, and color.
  This does not close the physical LiDAR gate below.
- [x] 2026-08-13 Slice 1 orientation-plan correction: viewer-aligned default,
  display-only Rotate/Mirror/Reset, persisted local presentation preference,
  220 Core tests, and complete 153/153 iPhone plus 153/153 iPad Simulator
  schemes passed. The readiness guard mutation failed red and passed restored.
  The owner accepted corrected physical-iPhone behavior. Physical iPad is
  waived for the present program and remains unverified.
- [x] 2026-08-13 Slice 2 local checkpoint: canonical four-dimension quality
  report, deterministic aggregation, bounded/deduplicated live coaching,
  accessible overlays, advisory Finish review, and exact explicit Save Anyway
  persistence passed focused Core/app/UI tests and both required mutation
  controls. The focused screenshot matrix retained 16 images per form factor
  across light/dark, default/accessibility Dynamic Type, live coaching, review,
  Finish/Save Anyway, and reopened persistence states.
- [x] 2026-08-13 Slice 2 final local matrix: 230/230 Core, 131/131 app unit,
  complete 160/160 iPhone Simulator, and complete 160/160 iPad Simulator
  schemes passed. Exact package resolution, unsigned device build, delivery
  inspection, selector test, golden digest, `git diff --check`, empty staged
  diff, and all non-signing static checks passed. The local `DEVELOPMENT_TEAM`
  remains intentionally uncommitted.
- [ ] Release owner: inspect AppIcon rendering, privacy report, App Store
  Connect data-use answers, permission copy, backup-container setup, and any
  required signing/capability configuration outside this repository.
- [ ] macOS/Xcode: visually inspect the compiled icon, archive the Release
  configuration, and validate signing/capabilities supplied by the release
  operator. No team/profile is committed here.
- [ ] Release owner: supply an approved absolute HTTPS Privacy Policy URL via
  `ROOMSCANSTUDIO_PRIVACY_POLICY_URL`, verify its in-app Privacy Policy link and
  App Store metadata URL, then validate the generated privacy report and App
  Store Connect answers. Do not infer legal approval from the source manifest.
- [ ] Account Holder: before distribution, choose and record either the current
  private-only empty-list rationale or the four-category disclosure (Precise
  Location, Photos or Videos, Environment Scanning, and Other User Content),
  including the Linked determination for each disclosed category.
- [ ] Review dependencies and licenses against [dependencies.md](dependencies.md)
  before adding or shipping any new package, converter, or SDK.
- [ ] Simulator/device: exercise camera and GPS denial, offline operation, and
  iCloud-disabled behavior; capture default and accessibility Dynamic Type
  screenshots on separate iPhone and iPad runs.
- [ ] Physical iPhone: complete every still-applicable protocol in
  [real-device-test-plan.md](real-device-test-plan.md). Physical iPad is waived
  for the present program and remains unverified.
- [ ] Photoreal LiDAR gate: complete all six colored-mesh checks in the real-device
  plan—0.5-source-pixel ARKit projection agreement, checkerboard bias, solid-patch
  midtones, multi-view photo comparison, matched scan health/performance, and
  minimum-device memory/cancellation—and attach the recorded evidence.
- [ ] iOS 26 background-coloring gate: complete all eight continued-processing
  checks in the real-device plan, including app switching/locking, system
  progress and cancellation, exactly-once background notifications, denied
  permission, expiration, force-quit recovery, performance/thermal recording,
  and the iOS 18-through-25 foreground fallback.
- [ ] External consumers: inspect ZIP/PDF/PNG/USDZ/share outputs and perform
  CloudKit development-container backup/recovery tests.
- [ ] AI redesign device gate: on a supported physical LiDAR iPhone,
  prove RoomPlan category mapping, entry-orientation suggestion/confirmation,
  AR camera pose/intrinsic conventions, mesh/depth/confidence availability,
  two-phase configuration, poor-tracking handling, and cleanup. SDK
  type-checking and Simulator runs do not close this gate. Physical-iPad
  behavior is owner-waived and unverified.
- [ ] Slice 2 physical iPhone quality gate: complete all seven controlled
  good/bad protocols in the real-device plan and retain exact region, evidence,
  Finish, Save Anyway, and reopen proof. Simulator and SDK evidence do not
  close this gate.
- [ ] Slice 2 physical iPad quality behavior is owner-waived for the current
  program and remains unverified. Do not check this item or make a physical
  iPad claim without a future retained device evidence set.
- [ ] AI redesign security gate: on real Face ID/passcode states, prove success,
  cancellation, failure, lockout, passcode fallback, backgrounding, enrollment
  change, and actor handoff before sensitive-action gating ships.
- [ ] AI redesign Share Sheet gate: on physical iPhone, exercise Files,
  AirDrop, an external app, completion, cancellation, error, dismissal fallback,
  and exactly-once export-lease cleanup. Physical-iPad behavior remains waived
  and unverified.
- [ ] Hosted-service gate: before provisioning or release, close the ADR's
  magic-link, Sign in with Apple federation/linking, immediate cache-aware link
  revocation, tenant/RLS context, deletion/restore, publication allowlist, and
  measured-cost spikes. No Slice 0 document or unit test is production-service
  evidence.
- [ ] Device/storage: complete the disk-cleanup and performance protocol in
  [storage-performance.md](storage-performance.md) with representative small
  and large room assets.

Unchecked items are release gates, not implied completed work.
