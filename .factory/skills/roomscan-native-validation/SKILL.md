---
name: roomscan-native-validation
description: Run RoomScanStudio native structural, Core, unsigned build, iPhone/iPad scheme and compiled-artifact checks. Use for native app/Core/PBX changes or requests for native validation; this does not authorize physical-device, signing, CloudKit or provider operations.
---

# Native validation

## Inputs and safety

Work from the repository root. Read root/Core/app instructions and
`.github/workflows/ci.yml`; commands below come from that workflow,
`Docs/setup.md`, and `Scripts/select_simulators.py`. Use macOS/Xcode with an
iOS 18-or-later SDK. Check free space and other active native jobs before running
the complete matrix. Serialize RoomScan's device tests; do not interrupt another
project or erase/delete simulators to resolve contention.

Use fresh owned result/build paths. Never substitute historical UUIDs, prior
`.xcresult` files or existing `.artifacts/` evidence. If only static tooling is
available, complete that tier and state that compilation/runtime checks are not run.

## Procedure

1. Capture the environment and inspect repository status:

   ```sh
   git status --short
   sw_vers
   xcodebuild -version
   xcodebuild -showsdks
   xcrun simctl list runtimes
   ```

2. Run the structural/selector/Python checks and complete Core suite:

   ```sh
   python3 -B Scripts/verify_xcode_scaffold.py
   python3 -B Scripts/select_simulators.py --self-test
   python3 -B -m unittest discover -s Scripts -p 'test_*.py'
   swift test
   xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj
   ```

   Stop on failure. Keep raw outputs if the task requires acceptance evidence.
   A scoped check is not a substitute for the full scaffold.

3. Allocate a fresh owned evidence root. This shell example adapts only CI's
   `$RUNNER_TEMP` paths; commands and flags are the real CI interfaces:

   ```sh
   mkdir -p .artifacts
   native_evidence=$(mktemp -d "$PWD/.artifacts/native-validation.XXXXXX")
   python3 -B Scripts/select_simulators.py \
     --github-output "$native_evidence/simulators.txt"
   ```

   The selector writes `iphone_destination=...`, `ipad_destination=...` and
   `runtime_identifier=...`; read those values without executing the file.
   Assign the exact discovered strings to `iphone_destination` and
   `ipad_destination`. If either family is missing, report the blocker rather
   than guessing an installed model.

4. Build the unsigned generic device artifact:

   ```sh
   xcodebuild -project RoomScanStudio.xcodeproj \
     -scheme RoomScanStudio -sdk iphoneos \
     -destination 'generic/platform=iOS' \
     -derivedDataPath "$native_evidence/build-derived" \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
   ```

5. Inspect the real compiled app with the current Slice 6 inspector:

   ```sh
   python3 -B Scripts/inspect_slice6_ios_artifact.py \
     --app "$native_evidence/build-derived/Build/Products/Debug-iphoneos/RoomScanStudio.app" \
     --output "$native_evidence/ios-artifact-inspection.json"
   ```

   It retains Slice 4/5 requirements and runs exclusion positive controls.
   Do not replace it with a source search or the older Slice 5 exclusion set.

6. Run the full scheme separately on both discovered destinations:

   ```sh
   xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
     -destination "$iphone_destination" \
     -resultBundlePath "$native_evidence/iphone.xcresult" \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

   xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
     -destination "$ipad_destination" \
     -resultBundlePath "$native_evidence/ipad.xcresult" \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
   ```

   Both app XCTest and XCUITest targets are enabled in the shared scheme.
   A focused/debugging run is not evidence of a full scheme. Preserve failed/
   interrupted results as diagnostic-only and use new paths for corrected runs.

7. For UI/acceptance changes, export actual attachments to fresh directories:

   ```sh
   xcrun xcresulttool export attachments \
     --path "$native_evidence/iphone.xcresult" \
     --output-path "$native_evidence/iphone-attachments"
   xcrun xcresulttool export attachments \
     --path "$native_evidence/ipad.xcresult" \
     --output-path "$native_evidence/ipad-attachments"
   ```

   Review hierarchy, Dynamic Type, contrast, VoiceOver order/labels, touch
   targets, overflow and safe areas. Keep bytes unedited and bind selected
   captures to named test attachments. Use the slice-acceptance skill if a
   complete freshness/approval record is requested.

## Completion report

Record exact commands, tool/runtime versions, discovered destinations,
pass/fail/skipped counts, artifact paths and limitations in the task report and
`Docs/verification-log.md`. Review `git diff --check` and status for generated
changes. Do not auto-clean existing artifacts.

Physical RoomPlan/LiDAR, Face ID/passcode, CloudKit, system share, signing and
App Store proof remain separate authorized operator gates in
`Docs/real-device-test-plan.md` and `Docs/release-checklist.md`. Do not mark them
complete from this procedure.
