# Device and browser compatibility matrix

## 2026-10-01 Slice 7 personal release

Tiers: **static** (source, structure or compilation only, no runtime),
**Simulator** (XCTest/XCUITest on an iOS Simulator), **physical device**
(XCUITest or manual checks on real hardware). Xcode 26.3 is the build
environment. Results are recorded in `Docs/verification-log.md` and in the
dated Slice 7 evidence record written at final acceptance.

| Target | OS | Tier | Coverage | Status and limits |
| --- | --- | --- | --- | --- |
| iPhone 17 Pro | iOS 26.6 | physical device | scoped UI tests + operator manual checklist (awaiting operator approval) | Scoped Trash, cloud backup deletion and end-to-end UI tests in isolated `--use-mock-fixture` / `--use-fake-cloud-backup` runs; manual items in `Docs/real-device-test-plan.md`. No LiDAR, Face ID, or live-iCloud verification is claimed. |
| iPhone 16 Pro Simulator | iOS 26.3 | Simulator | full `RoomScanStudio` scheme | Fixture capture and fake backup only; not physical capture or real iCloud. |
| iPad (10th generation) Simulator | iOS 26.3 | Simulator | full `RoomScanStudio` scheme | Fixture capture and fake backup only; physical iPad remains waived and unverified. |
| iOS 18 deployment floor | iOS 18 | static | compile-only (no runtime evidence) | The app's deployment target is iOS 18; no iOS 18 Simulator or device run was performed. |
| Browsers (portal and professional web) | Desktop and mobile Chromium, as in Slice 6 | static for Slice 7 (no rerun); Slice 6 synthetic browser evidence | unchanged from Slice 6 | Slice 7 made no web change. See the [Slice 6 closure record](evidence/2026-09-20-ai-redesign-slice-6-closure.md). |

**2026-10-02 update.** With operator approval, the four scoped UI tests (three
lifecycle tests and the end-to-end test) passed on the iPhone 17 Pro
(iOS 26.6, 23G71) in isolated `--use-mock-fixture` / `--use-fake-cloud-backup`
runs, after a device-only storage defect was fixed. The manual checklist in
`Docs/real-device-test-plan.md` was not executed, and no LiDAR, Face ID or
live-iCloud verification is claimed. Both Simulator rows passed the full scheme again (412 total, 411 passed,
0 failed, 1 skipped on each). See the
2026-10-02 reconciliation in the
[Slice 7 evidence record](evidence/2026-10-01-ai-redesign-slice-7-personal-release.md).
