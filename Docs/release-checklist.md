# Release checklist

Status: **Verified on Windows** items below are static only. **Pending macOS CI**
and external/device items remain unchecked until observed.

- [x] Windows static: `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=1`,
  app language mode Swift 5.0, package tools 5.9, 1024px opaque RGB AppIcon
  header, and required-reason privacy manifest contract parsed.
- [x] Windows static: CI workflow pins checkout/upload actions by full SHA,
  discovers iPhone/iPad simulators dynamically, and preserves xcresults.
- [x] Windows static: Dynamic Type source/test contracts, semantic contrast
  calculations, fixed-dark surface roles, and no fixed user-facing font sizes
  passed the structural oracle.
- [ ] macOS CI: resolve the package, run `swift test`, build unsigned generic
  iOS, then run app/UI tests on dynamically selected iPhone and iPad simulators.
- [ ] Release owner: inspect AppIcon rendering, privacy report, App Store
  Connect data-use answers, permission copy, backup-container setup, and any
  required signing/capability configuration outside this repository.
- [ ] macOS/Xcode: compile the asset catalog, visually inspect the icon, archive
  the Release configuration, and validate signing/capabilities supplied by the
  release operator. No team/profile is committed here.
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
- [ ] Physical iPhone/iPad: follow [real-device-test-plan.md](real-device-test-plan.md).
- [ ] External consumers: inspect ZIP/PDF/PNG/USDZ/share outputs and perform
  CloudKit development-container backup/recovery tests.
- [ ] Device/storage: complete the disk-cleanup and performance protocol in
  [storage-performance.md](storage-performance.md) with representative small
  and large room assets.

Unchecked items are release gates, not implied completed work.
