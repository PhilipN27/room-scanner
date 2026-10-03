# Slice 7 local personal release verification — 2026-10-01

Status: **Simulator and static gates PASS on the final working tree. The
physical-device runs, the signed Release archive and the iCloud container gate
were not run; they await explicit operator approval.** Slice 7 is therefore
locally verified on Simulator only. It is not closed as a personal release, it
is not an App Store or TestFlight release, and nothing was deployed.

> **2026-10-02 update:** the device lifecycle runs and the signed Release
> archive were later run with operator approval, and the device run found a
> second production defect. See
> [the 2026-10-02 reconciliation](#reconciliation-2026-10-02-device-lifecycle-signed-archive-and-a-device-only-storage-defect)
> at the end. The text above that section is unchanged.

Mission start commit: `81c3de6`. Repository `HEAD` during these runs:
`44604e5`, with the Slice 7 work uncommitted in the working tree. No commit,
push, TestFlight upload, App Store submission, CloudKit Production schema
change, or hosted-service change was performed. `HostedService/` is unchanged
since `81c3de6` and no migration `0010` exists.

## Evidence tiers

| Tier | Meaning in this record |
| --- | --- |
| static | Host-only structural checks, Python verifier tests and source inspection; no compilation. |
| Simulator | Compiled app, XCTest and XCUITest on the pinned iOS 26.3 Simulators, with `--use-mock-fixture` and `--use-fake-cloud-backup` isolated roots. Not LiDAR, Face ID, live iCloud or system-share evidence. |
| physical device | A signed build on the operator's iPhone. **Not run in this record.** |
| operator manual (not executed) | Checklist items in `Docs/real-device-test-plan.md` and `Docs/icloud-setup.md` that only a person with the device and container can perform. |

## What this verification covers

- Backup deletion: the durable deletion journal, explicit per-record and
  whole-project deletion, the two-choice Delete-now dialog, the pending-deletion
  section with retry and "Delete pending backups", and the purge/reaper hook
  that only journals. The app never deletes backups at launch or from the
  reaper. Outcome text states that Apple completes erasure later and that the
  app cannot verify physical erasure.
- Release engineering: the `Configs/Operator.xcconfig` signing channel, the
  app runpath, the inherited privacy-policy URL,
  `ITSAppUsesNonExemptEncryption = false`, and the scaffold verifier checks
  with paired controls in `Scripts/test_verify_xcode_scaffold_slice7.py`.
- The composed end-to-end XCUITest
  `RoomSlice7EndToEndUITests/testSlice7PersonalReleaseEndToEnd`.

### Production defect found by the end-to-end test

The AI package workspace had no visible Close button. `RoomAIRedesignHostView`
attached its `ai.close` toolbar item outside the `NavigationStack` owned by
`RoomAIRedesignView`, so SwiftUI never rendered it. Once a package reached
review, interactive dismissal was also blocked, which left the sheet with no
way out. The defect dates from Slice 3. Close is now passed into the screen as
`RoomAIRedesignCloseAction` and rendered inside its own navigation container,
with the same disabled rule as before (disabled while sharing or after
approval). The fixture screen passes no action and is unchanged.

The failing control is retained: the first end-to-end run failed at
`ai.close` and its hierarchy shows the "AI Room Package" navigation bar with no
button (`mutations-2026-10-01/ai-close-red-before-fix/`). Every later
end-to-end run passed through Close.

## Commands and results

All native commands ran on macOS 26.3.1 with Xcode 26.3 (17C529). Full-scheme
and build commands used fresh DerivedData under `/tmp/roomscan-s7-final/`.
Exact command lines are retained beside each log as `<step>.command`.

| Check | Command | Result | Tier |
| --- | --- | --- | --- |
| Scaffold verifier | `python3 -B Scripts/verify_xcode_scaffold.py` | `Static structure passed`, exit 0 | static |
| Simulator selector | `python3 -B Scripts/select_simulators.py --self-test` | exit 0 | static |
| Python verifier tests | `python3 -B -m unittest discover -s Scripts -p 'test_*.py'` | `Ran 89 tests`, `OK` | static |
| Slice 7 verifier controls | `python3 -B -m unittest Scripts/test_verify_xcode_scaffold_slice7.py -v` | 10 tests, `OK` | static |
| Core | `swift test` | `Executed 366 tests, with 0 failures` | macOS |
| Unsigned generic iOS build | `xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/roomscan-s7-final/generic CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -jobs 4 build` | `** BUILD SUCCEEDED **`; no provisioning, team or entitlement-mismatch line | macOS compile |
| Compiled-app inspection | `python3 -B Scripts/inspect_slice6_ios_artifact.py --app <generic Debug-iphoneos app> --output .../ios-artifact-inspection.json` | exit 0 | static on compiled app |
| Simulator build-for-testing | `xcodebuild build-for-testing ... -destination 'platform=iOS Simulator,id=9BF8FA07-B824-4C7A-AD7C-A7C09B4D23A1' -derivedDataPath /tmp/roomscan-s7-final/sim CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` | `** TEST BUILD SUCCEEDED **`, `.xctestrun` produced | macOS compile |
| Runpath | `otool -l <app>/RoomScanStudio \| grep -A2 LC_RPATH` (Simulator and generic device builds) | both list `path @executable_path/Frameworks` | static on compiled app |
| Full iPhone scheme | `xcodebuild test -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -destination 'platform=iOS Simulator,id=9BF8FA07-B824-4C7A-AD7C-A7C09B4D23A1' -derivedDataPath /tmp/roomscan-s7-final/sim -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath .artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/iphone-full.xcresult CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` | 403 total: 402 passed, 0 failed, 1 skipped; iPhone 16 Pro, iOS 26.3.1 Simulator | Simulator |
| Full iPad scheme | same command with `-destination 'platform=iOS Simulator,id=FDDEC0DB-DB75-4FBA-8344-69E2A2819531'` and `ipad-full.xcresult` | 403 total: 402 passed, 0 failed, 1 skipped; iPad (10th generation), iOS 26.3.1 Simulator | Simulator |
| End-to-end, single method | `xcodebuild test-without-building ... -only-testing:RoomScanStudioUITests/RoomSlice7EndToEndUITests/testSlice7PersonalReleaseEndToEnd -destination 'platform=iOS Simulator,id=9BF8FA07-B824-4C7A-AD7C-A7C09B4D23A1' -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath .../e2e-iphone.xcresult` | 1 passed, 0 failed; 18 valid PNG attachments | Simulator |
| Device runpath proof | `xcodebuild ... -destination 'id=<device-udid>' build-for-testing` plus one scoped UI test | **not run; awaiting approval** | physical device |
| Milestone 3 device lifecycle | signed `build-for-testing` and scoped lifecycle UI tests on `-destination 'id=<device-udid>'` | **not run; awaiting approval** | physical device |
| Release archive | `xcodebuild archive ... -destination 'generic/platform=iOS' -allowProvisioningUpdates` | **not run; awaiting approval** | signed archive |

The single skip on both families is
`testTrashIncreaseContrastKeepsListOrderAndDetailLegible`. It calls
`XCTSkipUnless(UIAccessibility.isDarkerSystemColorsEnabled, ...)` and runs in
its own Increase Contrast selection. The pre-change baseline skipped the same
test. No other iPad-specific skip occurred.

Freshness: `find RoomScanStudio RoomScanCore -name '*.swift' -newer
<bundle>/Info.plist` is empty for both full-scheme bundles, so no source file
changed after either run. The two bundles have different paths and different
`Info.plist` digests.

The selector's dynamic iPhone choice was another project's booted Simulator
(PlateLog). The pinned RoomScan iPhone 16 Pro and iPad (10th generation)
Simulators named in the validation contract were used instead. A 60-second
process monitor recorded no foreign `xcodebuild` or `xctest` process from the
start of the final matrix to its end.

### Pre-change baseline

Before the backup-deletion work, the same iPhone scheme on the previous
uncommitted tree passed: 379 total, 378 passed, 0 failed, 1 skipped (the same
contrast skip). The final iPhone total is 24 higher: 17 deletion unit tests and
7 new UI tests (six backup-deletion tests and the end-to-end test).

## Mutation controls

Each mutation was applied alone to the live source, rebuilt, and run against
`RoomScanStudioTests/RoomCloudBackupDeletionAppTests` (17 tests). The original
file was then restored and its SHA-256 checked against the pre-mutation value.
After all four, the restored tree passed 17/17.

| Mutation | Expected failing test | Observed failing assertions |
| --- | --- | --- |
| M1: `performBackupDeletion` treats every outcome as complete | `testPerformRemovesRecordOnlyWhenNothingRemains` | line 277: journal record missing after a partial delete |
| M2: journal skips the symlinked-ancestor check | `testJournalRejectsUnsafeIdentifiersSymlinksAndNonRegularFiles` | lines 218–220: writes through a symlinked parent succeeded |
| M3: purge journals after removing the package | `testPurgeJournalsBeforePackageRemovalFailsClosedAndSkipsWhenDisabled` | line 508 (journal saw the package absent), line 521 (fail-closed package deleted) |
| M4: the purge requester also performs the remote delete | `testReaperOnlyJournalsAndNeverCallsTheTransport` | lines 573–598; two purge-requester tests also failed on their zero-transport-call checks |

## End-to-end scenario

One test, four launches, one isolated root token. Every launch passes
`--ui-testing --reset-local-store --use-mock-fixture --use-fake-cloud-backup
--isolated-root-token=<token>`; launches 2–4 add `--keep-isolated-root`, and
only launch 4 adds `--trash-clock=<second trash time + 31 days>`.

1. Scan (mock fixture), review, save `ui-project-001`, save an orientation,
   prepare the AI package to the review-ready state, and close it.
2. Concept import needs the system file picker, which XCUITest cannot drive.
   This step relaunches the same root with `--slice3-ui-fixture` and imports a
   loose concept on the picker-less fixture screen. Screenshots 05 and 06 show
   that fixture surface (`revision-fixture-003`), not `ui-project-001`.
3. Export (USDZ/PDF head export ready), fake backup, recover as a copy, then
   Trash → Restore → Trash → Delete now with backup removal. The project is
   absent under Active, Archived and Trash, and the outcome states that the
   app cannot verify physical erasure, with no pending deletion. A second
   project is saved and trashed.
4. Relaunch with the forced clock. Trash and Active are both empty.

Two attempts of the formal single-method run exist. Attempt 1 failed at its
first navigation: the press on `home.newRoomScan` landed while Home was still
settling after launch and did not navigate (no foreign build was running). The
test now presses once more only if the source control is still on screen; the
destination assertion is unchanged. Attempt 1 is retained as diagnostic.

## Test-side corrections during this verification

- iOS 26 exposed the record-delete confirmation as nested button aliases. The
  tests now use the existing helper that collapses only identical
  label/frame aliases and still fails on two distinct choices.
- At Accessibility XXXL, alert choices scroll inside the alert. A helper
  scrolls the alert to reach them. The pending-deletion controls sit about
  3,100 points down the settings page, so that test scans forward with a
  90-second budget instead of the alternating sweep.

## Deviations from the plan

- Deletion APIs take an explicit `containerIdentifier`, so a journaled request
  stays bound to the container it was made against.
- Per-record failures are reported as strings, not typed errors, in the
  outcome.
- A seeded-backups launch flag was not needed: tests create backups through
  the persisted fake transport.
- The run-all control is labeled "Delete pending backups".
- Concept import in the end-to-end test uses the fixture relaunch above.

## Retained artifacts

Paths are relative to the repository root. `.artifacts/` is git-ignored and
exists on this Mac only. For `.xcresult` directories the digest is of the
bundle's `Info.plist`; for the screenshot directory it is of its
`manifest.json`.

| Artifact | Path | SHA-256 |
| --- | --- | --- |
| Full iPhone scheme xcresult | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/iphone-full.xcresult/Info.plist` | `a6743ca2d10c5a7b595318f5ad0887d3a49d548d7d1c127351fb76b0c147f0c0` |
| Full iPhone summary | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/iphone-summary.json` | `111a6a4f48fe3d26282f46fffbdef1b8ddeb7f4a8217bbdb0b9a98308d028728` |
| Full iPhone log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/iphone-full.log` | `13730fb41461e118ed7ccb208df6ff216944e527527608712fbc9d17eeb28039` |
| Full iPad scheme xcresult | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/ipad-full.xcresult/Info.plist` | `73e8b76428c79fefba173c8afcd90135b602ff8c17990f259fd4dda24241586a` |
| Full iPad summary | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/ipad-summary.json` | `efcc5a6cfd2db147ba08d07a51da09aaf4025f6cd9a16d64e76bbc0343c16b73` |
| Full iPad log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/ipad-full.log` | `d1ad66dea94ccb9f2edf999384e80d79c8b6594704062c7fa565dd98f86398f4` |
| Matrix step results | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/steps.txt` | `62e9920610b70e452f05a62604b0dbdc89a2df9d0bb3a624a935baed4c1bd75b` |
| Environment | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/environment.txt` | `87ebeedcdb0fbd88eb9b78af3dcb922ddd385af58637752addf658179407cf85` |
| Scaffold log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/scaffold.log` | `d158a487710f46f6d70f53f12079a3bcd0d03a371be60ccfe2c1691091e6af60` |
| Python discover log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/python-unittest.log` | `a2f4844ad8269c1fccf4f8d931ee0cfe1805665c3ec9c0d75ab5b7e06ff351df` |
| Slice 7 verifier controls log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/python-slice7-verbose.log` | `da7474deb7dea4c0efedf4db3a48c8fde46f002c32c5ca41f93837a27e370841` |
| Core log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/swift-test.log` | `c6173eaaf37073822b224ae95e3b551b5615dda4cf5f8cee9f7a0c0cc21a5123` |
| Unsigned generic build log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/unsigned-generic-build.log` | `93e548ee24acfead1f6f06fba1f51e7a9f271277b4a54c246e39b301ddb66f38` |
| Compiled-app inspection | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/ios-artifact-inspection.json` | `88753ef51d9df5f3e643ee5cb4409ba17ee77bea4e83e11ab9e85a628dc44fce` |
| Simulator build-for-testing log | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/simulator-build-for-testing.log` | `0f050c2be3f67aae93d94eec13d9d97c28edfed8ac21fbb57c9f8165c0de1bd7` |
| Simulator rpath | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/otool-simulator-rpath.txt` | `c7909c4e06866689b8dbc8a5e88f91d1de8f5cc5448ca02a422d495c418c66ce` |
| Device-build rpath | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/otool-device-rpath.txt` | `6253eaaffa238ddadc6fbe247b29753f57847db3db3a5fd9ecafa8abb3b7b71f` |
| Build settings excerpt | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/show-build-settings.txt` | `5a13d74eb7ddb1f3fba5eea289a2ba4ec7f5b21f32eb031fd6ded29216380b67` |
| End-to-end xcresult (attempt 2, passed) | `.artifacts/slice7-personal-release-2026-09-30/gates/e2e-iphone-2026-10-01/e2e-iphone.xcresult/Info.plist` | `ee83f8f553cfa9c5eb6e06f65547b1c046ef5928373cb75c162daf137a2f1958` |
| End-to-end summary | `.artifacts/slice7-personal-release-2026-09-30/gates/e2e-iphone-2026-10-01/e2e-iphone-summary.json` | `7ef8048056890c221ed75f507941283873d360cdada6aab691a2444fb157c039` |
| End-to-end log | `.artifacts/slice7-personal-release-2026-09-30/gates/e2e-iphone-2026-10-01/e2e-iphone.log` | `8b60f65ae8380c13fd5cf9b838820a5542def4852e1bc74cfa52fffaa78cc580` |
| End-to-end attachment export manifest | `.artifacts/slice7-personal-release-2026-09-30/gates/e2e-iphone-2026-10-01/e2e-iphone-attachments/manifest.json` | `f5b889e4b8a58d3429ad882f0b2eed545118e1933d2d3320602aa0acc098363c` |
| End-to-end attempt 1 xcresult (diagnostic, failed) | `.artifacts/slice7-personal-release-2026-09-30/gates/e2e-iphone-2026-10-01/attempt1-diagnostic-failed.xcresult/Info.plist` | `71ccefd69d6e0bc2be146d4597fadf3cda38a277f280df73a068597e818ff3b9` |
| End-to-end attempt 1 log (diagnostic) | `.artifacts/slice7-personal-release-2026-09-30/gates/e2e-iphone-2026-10-01/attempt1-diagnostic-failed.log` | `245cf46f7a057daf7db68bcdbf9b410db90181193e94a33496bfaa9b01badfcf` |
| Promoted screenshots (manifest) | `Docs/evidence/2026-10-01-ai-redesign-slice-7-screenshots/manifest.json` | `f6a00fd076b77af9500eb80891b41b6f0fb2108ffc10f7e8d7d2026860ee824c` |
| Mutation summary | `.artifacts/slice7-personal-release-2026-09-30/mutations-2026-10-01/summary.json` | `55ee88f7138ea4bcb7a5296e1751d3899f711ff5dacf7e45086c55fe2b5828b2` |
| Mutation restored run log | `.artifacts/slice7-personal-release-2026-09-30/mutations-2026-10-01/restored-test.log` | `e595ab705875500a50d0b62b33c48a9933e7d7fffd5d0724ab46b89c4b212626` |
| AI Close failing control log | `.artifacts/slice7-personal-release-2026-09-30/mutations-2026-10-01/ai-close-red-before-fix/ui-slice7-1.log` | `18b6f1259afb7ae1b189bc7251b73f87e3f70a27baf93e23895d1957dd6821e2` |
| AI Close failing hierarchy | `.artifacts/slice7-personal-release-2026-09-30/mutations-2026-10-01/ai-close-red-before-fix/failed-hierarchy-no-ai-close.txt` | `11fd5910e52f43e37627b895ddfa852d41c578f72f5580f955392d232e66f0b0` |
| Pre-change baseline iPhone xcresult | `.artifacts/slice7-personal-release-2026-09-30/gates/baseline-2026-10-01/baseline-iphone-full.xcresult/Info.plist` | `badd02d22811d087b9e82ba9ba015a10115361ac6393c6eebd04ef6c96ee08cc` |
| Pre-change baseline summary | `.artifacts/slice7-personal-release-2026-09-30/gates/baseline-2026-10-01/baseline-iphone-summary.json` | `05f519aff5ac4c4bff881184feb0ff2d3facf0571c925a01130323ffe191e60b` |
| Checksum list for all rows above | `.artifacts/slice7-personal-release-2026-09-30/gates/final-2026-10-01/SHA256SUMS` | `c86b2fbdd7a4f4268dc90da1df6b2b7217effc8ddac12423ecdd29ade8abe0df` |

The device runpath (`m1-device-runpath/`), Milestone 3 device
(`m3-device-lifecycle/`) and archive (`archive/`) directories exist but are
empty, because those runs were not performed.

## iCloud container `iCloud.org.roomscanstudio.app`

Neither outcome has been observed yet. No entitled build was attempted, so it
is unknown whether the container is assigned to the App ID. The device
lifecycle run and the Release archive are **blocked pending operator
approval**, not passed. Nothing in this record verifies live iCloud, physical
erasure, LiDAR capture, Face ID or a TestFlight upload.

## Remaining gates

1. Create the git-ignored `Configs/Operator.local.xcconfig` and
   `Configs/RoomScanStudio.local.entitlements` from the examples (team only in
   the local file).
2. Device runpath proof and the Milestone 3 lifecycle run on the operator's
   iPhone, then uninstall the test build.
3. Signed Release archive, without export or upload.
4. Manual real-iCloud checks in `Docs/icloud-setup.md`, then deploy the schema
   to Production in CloudKit Console before any TestFlight build.

## Reconciliation 2026-10-02: device lifecycle, signed archive and a device-only storage defect

Status: **the Milestone 3 device lifecycle tests and the composed end-to-end
test passed on the operator's iPhone, the signed Release archive was built
and inspected without export, and the final Simulator matrix passed on iPhone
and iPad (412 total, 411 passed, 0 failed, 1 skipped on each).**
The device run exposed a production defect that the Simulator cannot show; it
is fixed below. Real iCloud operations, physical erasure, LiDAR capture, Face
ID, TestFlight, App Store submission and the CloudKit Production schema remain
unverified. The operator chose not to exercise real iCloud in this pass. No
commit, push, export, upload or hosted-service change was performed.

The operator approved, for this pass only: local signing files, the Milestone
3 device lifecycle runs, a Release archive without export or upload, and the
iCloud entitlement in the local entitlements file. Device: iPhone 17 Pro,
iOS 26.6 (23G71), paired to this Mac; its identifier is redacted as
`<paired-device>` in every retained text file. Xcode 26.3 (17C529).

### Production defect 2: app storage rejected on every physical device

On a device the app container is reported as `/var/mobile/...`, and
`resolvingSymlinksInPath()` strips `/private`, so every storage root passes
through the system link `/var -> private/var`. Six private ancestor walkers
rejected any symlinked ancestor, so on a device they refused every path:

- `RoomCloudBackupDeletionJournal` ("The room package could not be deleted"
  in Delete now with backup removal)
- the AI package provenance registry in `RoomAIRedesignModelFactory.swift`
  ("Local AI package provenance storage is unsafe", so the AI workspace never
  opened)
- `ProfessionalProjectSyncJournal`, `ProfessionalProjectRecoveryCoordinator`
  and `ProfessionalProjectSyncService`
- `PublicationOperationJournal`

The Simulator's container path has no symlinked ancestor, so every Simulator
run passed. The defect affects any device build, not only Slice 7.

Fix: all six walkers now call
`RoomStorageAncestorSafety.existingAncestorsAreSafe(of:fileManager:)`
(`RoomScanStudio/Infrastructure/Persistence/RoomStorageAncestorSafety.swift`)
and keep their own error types. It trusts a symlink only when it is directly
under `/` and owned by root. The app runs as a non-root user and cannot create
such a link, so any link the app or another writer could plant still fails
closed at every depth.

`RoomScanStudioTests/RoomStorageAncestorSafetyTests` (9 tests) routes each
store through the host's root-owned `/tmp` link. It also checks that
app-created links fail at every depth, that a root-owned link below the top
level is still rejected (found at runtime under `/usr/bin`), and, with a fake
`FileManager`, that a top-level link is trusted only when root-owned.

- Red control before the fix (`device-path-ancestor-fix/red-before-fix.*`):
  7 tests, 6 failed with the device errors (`unsafeStorage`, `unsafeJournal`,
  `unsafeScratch`); the app-created-link control passed. The last two tests
  above were added later for the mutation work.
- Green: the app unit suite passed 352/352 on the iPhone 16 Pro Simulator
  (`device-path-ancestor-fix/green-app-unit.*`).
- Mutation controls, each applied alone and restored
  (`device-path-ancestor-fix/mutations/summary.json`; helper SHA-256
  `912098ea…66754e3` before and after). Baseline 9/9 passed.

| Mutation | Result |
| --- | --- |
| M5: accept every symlink | 5 tests failed |
| M6: drop the top-level condition | 1 failed: `testRootOwnedLinkBelowTopLevelIsStillRejected` |
| M7: drop the root-owner condition | 1 failed: `testTopLevelLinkIsTrustedOnlyWhenRootOwned` |

M7 survived the first round, which had only the first seven tests. That round
is retained in `device-path-ancestor-fix/mutations-round1-m7-survived/`; the
fake-`FileManager` test was added to kill it.

### Device runs

Scoped list (`m3-device-lifecycle/only-testing.txt`):
`testBackupRecordDeletionRequiresConfirmationAndReportsHonestOutcome`,
`testDeleteNowWithBackupRemovalGoesPendingOnOfflineFailureAndRetryDeletes`,
`testTrashLifecycleConfirmationRestoreArchiveAndDeleteNowPreserveOtherProject`
and `RoomSlice7EndToEndUITests/testSlice7PersonalReleaseEndToEnd`. Builds used
`xcodebuild build-for-testing -project RoomScanStudio.xcodeproj -scheme
RoomScanStudio -destination 'id=<paired-device>' -allowProvisioningUpdates
-derivedDataPath /tmp/roomscan-s7-device`, then `xcodebuild
test-without-building` with the same destination and the scoped list. All
launches use the fake backup transport and isolated roots.

| Attempt | Outcome | Cause | Retained |
| --- | --- | --- | --- |
| 1 | Build failed | Test bundles inherited the app entitlements | log, command |
| 2 | No test ran | Phone locked; UI-automation authentication cancelled | log, xcresult |
| 3 | 2 passed, 2 failed | Defect 2: Delete now with backup removal and the AI workspace failed | log, xcresult |
| 4 | Invalid | An incoming call and manual phone use interrupted the run | log only; xcresult deleted (personal content) |
| 5 | 3 lifecycle passed; end-to-end failed at line 85 | Raw-consent switch stayed off | log, xcresult |
| 6 | Invalid, all 4 failed | Phone was in landscape; tests assume portrait | log only; xcresult deleted (home screen frame) |
| 7 | 3 lifecycle passed; end-to-end failed at line 85 | Switch knob below the visible edge (see below) | log, xcresult |
| 8 | 3 lifecycle passed (69.6 s, 123.0 s, 361.5 s); end-to-end passed line 85, then failed at line 137 | Phone rotated and disconnected mid-test; empty hierarchy | log only; xcresult deleted (possible home screen frame) |
| 9 | End-to-end **passed** (350.7 s), portrait throughout | — | log, xcresult, 18 screenshots reviewed |

Attempts 4 onward include the defect 2 fix. Attempts 8 and 9 used the same
signed test build (`attempt8-9-build-for-testing.*`), so on that build all
four scoped tests passed. The lifecycle tests also passed in attempts 5 and 7
on earlier builds; only `RoomSlice7EndToEndUITests.swift` changed between
those builds. Attempt 8's lifecycle passes are evidenced by its log only,
because its bundle was deleted with operator approval. Attempts 7 and 5 keep
bundles with the same three passes.

Before every deletion, the attachments were exported and reviewed. Bundles
that showed content outside the app (a home screen, an incoming call) were
deleted with operator approval, and only the redacted text log was kept. The
attempt 9 screenshots show only the app and synthetic fixture data. The
device identifier was redacted from all retained text logs and command files.
The `.xcresult` bundles still hold device metadata internally; they are
git-ignored and stay on this Mac.

After the runs, `xcrun devicectl device uninstall app` removed
`org.roomscanstudio.app` and `org.roomscanstudio.app.uitests.xctrunner`, and
the app listing then showed no RoomScan app (`m3-device-lifecycle/device-uninstall.txt`).

The separate device runpath proof (`m1-device-runpath/`) was not run. The
signed app launched and ran the four scoped tests on the device, and the
Release binary has no `@rpath` dependencies (see the archive below).

### Test-side corrections from the device runs

Both changes are in `RoomSlice7EndToEndUITests.swift`. The line 85 assertion
(`rawConsent.value == "1"`) is unchanged.

- `toggle` tapped, read the value at once, and tapped again if it looked
  unchanged; on a device the read could come before the switch updated. It
  now waits up to 5 seconds for the value to change before one retry.
- `scrollFullyIntoView` replaced `scrollIntoView` for the two switches. On
  the iPhone the raw-consent row spanned y 844–972 on an 874-point screen.
  XCUITest reported it hittable because part of the row was visible, but the
  knob (y 894–922) was off screen, so both taps missed (attempt 7). The helper
  drags slowly until the whole frame is inside the scroll view. On the
  Simulator the row was already fully visible, so no drag ran there.

### Signing deviation

Device attempt 1 failed because `CODE_SIGN_ENTITLEMENTS` also applied to the
test bundles. The local and example xcconfig now set
`CODE_SIGN_ENTITLEMENTS = $(ROOMSCANSTUDIO_ENTITLEMENTS_$(WRAPPER_EXTENSION))`
with `ROOMSCANSTUDIO_ENTITLEMENTS_app` naming the entitlements file, so only
the `.app` wrapper gets entitlements. `Docs/setup.md` step 2 describes this.

### Signed Release archive (no export)

Command (`archive/archive.command`): `xcodebuild archive -project
RoomScanStudio.xcodeproj -scheme RoomScanStudio -configuration Release
-destination 'generic/platform=iOS' -archivePath
.artifacts/slice7-personal-release-2026-09-30/archive/RoomScanStudio.xcarchive
-derivedDataPath /tmp/roomscan-s7-archive -allowProvisioningUpdates`.
Result: `** ARCHIVE SUCCEEDED **`. No `-exportArchive`, upload or
notarization was run. Inspection is in `archive/archive-inspection.txt`:

- `codesign --verify --deep --strict`: valid on disk and satisfies its
  designated requirement. `TeamIdentifier` equals the operator's team in the git-ignored local
  xcconfig (value recorded only in the inspection file), identifier
  `org.roomscanstudio.app`, arm64.
- Signed with an Apple Development identity and an iOS Team Provisioning
  Profile, so `get-task-allow` is true. This is a development-signed archive
  for the operator's own devices, not a distribution build.
- Entitlements: `com.apple.developer.icloud-container-identifiers =
  [iCloud.org.roomscanstudio.app]`, `icloud-services = [CloudKit]`.
- `ITSAppUsesNonExemptEncryption = false`, `MinimumOSVersion = 18.0`,
  version 1.0.0 (1).
- No `Frameworks` directory. The binary links only system frameworks and
  libraries (0 `@rpath` dependencies), so the MetalSplatter packages are
  linked statically.
- The Apple ID email in the signing identity is redacted in the inspection
  and log. It remains inside the archive's signature and `Info.plist`, which
  stay git-ignored on this Mac.

### iCloud container `iCloud.org.roomscanstudio.app`: case (a) observed

The archive's embedded provisioning profile lists
`iCloud.org.roomscanstudio.app` in `icloud-container-identifiers`,
`icloud-container-development-container-identifiers` and
`ubiquity-container-identifiers`, for both Development and Production
environments. So the container is assigned to the App ID
(`Docs/icloud-setup.md` (a)). No CloudKit request was made: every device and
Simulator test used `--use-fake-cloud-backup` or the unconfigured path.

### Finding: an unsigned build with a configured container traps

The first 2026-10-02 Simulator matrix ran with the git-ignored
`Configs/Operator.local.xcconfig` present, which injects the container
identifier. With `CODE_SIGNING_ALLOWED=NO` the app has no iCloud entitlement,
so the Check account action trapped inside `CKContainer(identifier:)`
(`EXC_BREAKPOINT`), and
`testCloudBackupIsDisabledAndUnconfiguredWithoutAutomaticLaunchOperation`
failed at line 1208. That iPhone run had 412 total, 410 passed, 1 failed and
1 skipped. It was stopped before the iPad lane and is retained as
`gates/final-2026-10-02-diagnostic-operator-config-present/` with the crash
report. Signed builds carry the entitlement, so this does not affect the
device runs or the archive. Operators must not run unsigned builds with a
container configured. The final matrix hid the operator file for its
duration, which matches CI.

### Final Simulator matrix (repository configuration)

Script: the same steps as the 2026-10-01 matrix, with fresh DerivedData under
`/tmp/roomscan-s7-final3/`. `Configs/Operator.local.xcconfig` was moved out of
the tree for the run (`operator-config.txt` records it absent). macOS 26.3.1,
Xcode 26.3 (17C529), `HEAD` `44604e5` with the Slice 7 work uncommitted.

The matrix process was killed from outside at about 21:20 local time, while
the iPad lane was running its last test (411 of 412 reported, none failed). Its
exit trap therefore did not run. The operator file was restored by hand, and
its SHA-256 before and after is identical (`operator-config-before.sha`,
`operator-config-after.sha`). The partial iPad log is retained as
`ipad-full-interrupted-diagnostic.log`. The iPad lane was then rerun in full
with `xcodebuild test-without-building` on the same build products, which were
compiled while the operator file was absent.

| Check | Command | Result | Tier |
| --- | --- | --- | --- |
| Scaffold verifier | `python3 -B Scripts/verify_xcode_scaffold.py` | `Static structure passed`, exit 0 | static |
| Simulator selector | `python3 -B Scripts/select_simulators.py --self-test` | exit 0 | static |
| Python verifier tests | `python3 -B -m unittest discover -s Scripts -p 'test_*.py'` | `Ran 89 tests`, `OK` | static |
| Slice 7 verifier controls | `python3 -B -m unittest Scripts/test_verify_xcode_scaffold_slice7.py -v` | 10 tests, `OK` | static |
| Core | `swift test` | `Executed 366 tests, with 0 failures` | macOS |
| Unsigned generic iOS build | `xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/roomscan-s7-final3/generic CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -jobs 4 build` | `** BUILD SUCCEEDED **`; no provisioning, team or entitlement-mismatch line; inspector exit 0 | macOS compile |
| Simulator build-for-testing | `xcodebuild build-for-testing ... -derivedDataPath /tmp/roomscan-s7-final3/sim CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` | `** TEST BUILD SUCCEEDED **`; both builds list `@executable_path/Frameworks` | macOS compile |
| Full iPhone scheme | `xcodebuild test -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -destination 'platform=iOS Simulator,id=9BF8FA07-B824-4C7A-AD7C-A7C09B4D23A1' -derivedDataPath /tmp/roomscan-s7-final3/sim -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath <gate>/iphone-full.xcresult CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` | 412 total: 411 passed, 0 failed, 1 skipped; iPhone 16 Pro, iOS 26.3.1 | Simulator |
| Full iPad scheme | `xcodebuild test-without-building` with the same project, scheme, DerivedData and flags, `-destination 'platform=iOS Simulator,id=FDDEC0DB-DB75-4FBA-8344-69E2A2819531'` and `ipad-full.xcresult` | 412 total: 411 passed, 0 failed, 1 skipped; iPad (10th generation), iOS 26.3.1 | Simulator |

The single skip on both is again
`testTrashIncreaseContrastKeepsListOrderAndDetailLegible`. The total is 9
higher than on 2026-10-01: the nine `RoomStorageAncestorSafetyTests`, which
passed on both. `testSlice7PersonalReleaseEndToEnd` passed inside both bundles
(5 m 50 s on iPhone, 5 m 38 s on iPad), with the revised `toggle` and
`scrollFullyIntoView` helpers. No Swift source under `RoomScanStudio/` or
`RoomScanCore/` is newer than either bundle's `Info.plist`. The promoted
2026-10-01 screenshots were not replaced.

### Retained artifacts (2026-10-02)

Paths are relative to `.artifacts/slice7-personal-release-2026-09-30/`.
`gates/final-2026-10-02b-repo-config/SHA256SUMS` lists 56 files, including
every other row below, the remaining matrix logs and the retained diagnostic logs.
For `.xcresult` and `.xcarchive` directories the digest is of `Info.plist`.
The Apple ID email was redacted from the four signed build logs and the
archive log before hashing.

| Artifact | Path | SHA-256 |
| --- | --- | --- |
| Full iPhone scheme xcresult | `gates/final-2026-10-02b-repo-config/iphone-full.xcresult/Info.plist` | `765decc4e49735e42918e17d300bcfa2281c650d520da8552e31977df0984729` |
| Full iPhone summary | `gates/final-2026-10-02b-repo-config/iphone-summary.json` | `ce689d9200906682a9903f7ad8867db20a762919cad1f5640014af6048f9c966` |
| Full iPhone log | `gates/final-2026-10-02b-repo-config/iphone-full.log` | `dcd9229b36895a79eeb57861bdf4e2a62a85482b7fef8dec154b3dc72946be12` |
| Full iPad scheme xcresult | `gates/final-2026-10-02b-repo-config/ipad-full.xcresult/Info.plist` | `d1a1ecd3d8b0994e68185ec1e73988fe59aa8147714e2846b4d7eab9e1be91f6` |
| Full iPad summary | `gates/final-2026-10-02b-repo-config/ipad-summary.json` | `6e5656ed1aadcb3704e6afdca672b45ac3fca218469ec701c2934d788fe2fd51` |
| Full iPad log | `gates/final-2026-10-02b-repo-config/ipad-full.log` | `acf3b2761560cf4ef0356a8fbf8b9f61eb3f6236d9c70c52a44ff9ab3e7228e9` |
| Matrix step results | `gates/final-2026-10-02b-repo-config/steps.txt` | `8d7088b878f7b0f0e71d97196cb8f51a41f985ef9ee593eb04ae9cc4215d9051` |
| Operator file absent during matrix | `gates/final-2026-10-02b-repo-config/operator-config.txt` | `e607f8c32e318bc01408dec9d7ad0200189133c803373de22211e8091d06aca1` |
| Diagnostic iPhone xcresult (operator file present) | `gates/final-2026-10-02-diagnostic-operator-config-present/iphone-full.xcresult/Info.plist` | `45a3cb4e5e470da3134f29dbc9abc84be4a9cf32703da271058e044b0dd05019` |
| Diagnostic iPhone summary | `gates/final-2026-10-02-diagnostic-operator-config-present/iphone-summary.json` | `b75c0922c5d8c894fc17f53fbbee1c01e5adf62fdfad080a325f52c0a7d2659b` |
| CloudKit trap crash report | `gates/final-2026-10-02-diagnostic-operator-config-present/cloudkit-unentitled-trap.ips` | `fe28104aa4da33c78cf9632d16563a90a89300456c933e68e9f1b3c4cf1759a4` |
| Ancestor fix red control log | `device-path-ancestor-fix/red-before-fix.log` | `e6701c2e93dbf0902c468e745c0250d753bf684c2a7a3055c543b00d12660608` |
| Ancestor fix green app unit log | `device-path-ancestor-fix/green-app-unit.log` | `7888179b77c1791c50231a3794ee173459ec492070439a4579cf9f1752059e63` |
| Ancestor mutation summary | `device-path-ancestor-fix/mutations/summary.json` | `bccfbcde78e9fa1234dc1eec90e6bf447a1971b391ea3c903c0d0b36bb60c4d2` |
| Device end-to-end xcresult (attempt 9) | `m3-device-lifecycle/attempt9-device-e2e.xcresult/Info.plist` | `25f83e6220a8904fa529a24d6dc50fae81151a12fab534b456428e05bb762230` |
| Device end-to-end log (attempt 9) | `m3-device-lifecycle/attempt9-device-e2e.log` | `066fb52757c6934bf848cb91bdff69a61fa864196e003a54ee4371d0fe667031` |
| Device lifecycle log (attempt 8) | `m3-device-lifecycle/attempt8-lifecycle-3-passed-e2e-device-moved.log` | `2663cec259c44c628eba97c12f99f820d71e4f5662756ce5b5b9d05c31bb2c0f` |
| Device test build log (attempts 8 and 9) | `m3-device-lifecycle/attempt8-9-build-for-testing.log` | `eb6febdc92a28da2685927f8a6c0e4df256f88f8d61e353f0baed7851e681290` |
| Device uninstall record | `m3-device-lifecycle/device-uninstall.txt` | `2da0d8b953d23e471f9433d9d50edaed6949395375974dac26b0b10e6f842b7c` |
| Archive command | `archive/archive.command` | `85399f79f7507ce049667fcb3c83783d27877fbd351e94c65c4083728ad72249` |
| Archive log | `archive/archive.log` | `9b6e01907f10d8d68afe89f7a034644078ec3423bd7f9a3c7fd71ee1c98ed7a0` |
| Archive inspection | `archive/archive-inspection.txt` | `9ff9022d35f6603004ff5b01281d3633c3f19d8706766d830847c4906df92631` |
| Archive `Info.plist` | `archive/RoomScanStudio.xcarchive/Info.plist` | `74943c1d07eb2c736b783bda31a83af50e53bf0903f4441901032c60e15e80d1` |
| Checksum list | `gates/final-2026-10-02b-repo-config/SHA256SUMS` | `9e37011bc359a523180e658663e1d5e85f3625050f9a5a78d74c7857a86475b6` |

### Remaining gates

1. Manual real-iCloud checks in `Docs/icloud-setup.md` on a signed build
   (account, upload, list, recovery, deletion and the pending-deletion retry),
   then deploy the schema to Production in CloudKit Console.
2. A privacy-policy URL. Settings shows "Privacy Policy not configured for
   this build", and distribution stays blocked until the operator supplies one.
3. LiDAR capture, Face ID, physical erasure and system-share checks from
   `Docs/real-device-test-plan.md`.
4. Any TestFlight or App Store distribution build, which needs a distribution
   identity, export and upload, none of which were approved here.
