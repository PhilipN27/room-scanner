# RoomScanStudio AI Redesign Platform Slice 7 Implementation Plan

## Redefinition — 2026-10-01

Slice 7 is redefined as a **local personal release**. The original master-plan
Slice 7 ("Retention, deletion, operations, and release proof") assumed a
deployed hosted product with subscribers, purge jobs, and a load-tested service.
None of that is deployed. The operator's goal for this slice is a personally
installable iPhone build with honest local deletion and private iCloud backup
deletion, plus the release engineering needed to sign, archive, and run it
under the operator's own Apple Developer account.

The hosted lifecycle work from the original checklist is deferred, not
implemented. The original six checklist bullets stay unchanged in the
[platform plan](2026-08-12-ai-redesign-platform.md), which gains a dated
reconciliation pointing here.

Mission start commit: `81c3de6`. Environment: Xcode 26.3; iPhone 16 Pro and
iPad (10th generation) Simulators on iOS 26.3; physical iPhone 17 Pro on
iOS 26.6 (device runs awaiting operator approval).

This plan is not evidence. Acceptance is recorded in the dated Slice 7 evidence
record (Docs/evidence/2026-10-01-ai-redesign-slice-7-personal-release.md,
written at final acceptance) plus dated entries in `Docs/verification-log.md`.
There is no aggregate Slice 7 verifier script.

## Scope

| In scope (local personal release) | Deferred | Reason for deferral |
| --- | --- | --- |
| 30-day local Trash with Restore, "Delete now", and automatic purge by a foreground reaper | Hosted trash, purge, and backup-expiry lifecycle (active-copy purge within 7 days, backup purge within 30 days) | No hosted deployment exists to purge; implementing unexercised hosted jobs would add unverified surface. |
| Permanent local deletion of the package and its companions (redesign state, Concept Sets, property membership, professional sync journal record, search index) | Hosted deletion routes | Professional sync and publication stay default-off; hosted routes would require a new sealed route manifest and live verification. |
| Explicit deletion of the user's private CloudKit backup records, journaled and retryable | Migration `0010` | No hosted schema change is needed for a local release; a forward-only migration without a deployed consumer is unjustified. |
| Operator signing channel (`Configs/Operator.xcconfig` plus git-ignored local files) | Contracts v4 | The v3 service contract remains current; no hosted contract changes in this slice. |
| `ITSAppUsesNonExemptEncryption` = false and the device runpath fix | Cancellation's 30-day read-only export grace | Requires subscriptions and hosted account lifecycle, neither of which ships. |
| Composed Simulator end-to-end UI test with isolated launch arguments | Load tests of portal derivatives, quotas, signed assets, comments, sync conflicts, and deletion jobs | No deployed service to load; synthetic local load would not represent production. |
| Documentation set, compatibility matrix, final Simulator matrix | Subscriber quotas and pricing | Requires measured upload, storage, and egress costs from real use. |
| Planned device runs and signed archive (awaiting operator approval) | App Store disclosures and nutrition labels | The release is a personal TestFlight (internal) scope with no App Store listing. |
| | AWS deployment | Provider accounts, credentials, and deployment require separate explicit authorization. |
| | A `verify_slice7_*.py` aggregate verifier under Scripts | Acceptance is the dated evidence record plus `Docs/verification-log.md`; no such script exists or is planned. |

## Task ledger

Statuses describe the working tree on 2026-10-01. "Done" means implemented with
recorded Simulator evidence in `Docs/verification-log.md`; it is not release
approval.

### Milestone 1: Trash lifecycle and device runpath fix

- [x] Core: optional `metadata.json` `trashedAt`, move to Trash and Restore,
  `projectTrashed` guards on every mutation and outbound input, 30-day
  retention policy. Evidence: `swift test` entries in
  `Docs/verification-log.md`.
- [x] Isolated token roots and relaunch infrastructure for UI tests
  (`--isolated-root-token=<token>`, `--keep-isolated-root`, `--trash-clock=`).
- [x] App purge coordinator and foreground Trash reaper with companion
  cleanup. Evidence: `RoomTrashLifecycleTests` scoped Simulator runs.
- [x] Library and room-detail Trash UI, relaunch durability and expiry tests.
  Evidence: scoped Simulator selections recorded in `Docs/verification-log.md`.
- [ ] Full iPhone and iPad schemes green for Milestone 1. Status: in
  progress; the latest recorded full iPhone gate was interrupted and must be
  rerun.
- [x] `LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"`
  in the app configurations (source change; see `Docs/setup.md`).
- [ ] Signed Debug launch on the physical iPhone confirming the runpath fix.
  Status: awaiting operator approval.

### Milestone 2: CloudKit backup deletion

- [x] Core deletion request contract
  (`RoomScanCore/Sources/RoomScanCore/RoomCloudBackupDeletion.swift`, schema
  `roomscan-cloud-backup-deletion-request-v1`) with Core tests.
- [x] Ownership-marked deletion journal
  (`RoomScanStudio/Infrastructure/CloudBackup/RoomCloudBackupDeletionJournal.swift`).
- [x] Apple transport deletion: project listing reuses the existing query,
  batches of at most 400 with `atomically: false`, batch halving on
  `limitExceeded`, `unknownItem`/`zoneNotFound` counted as already deleted.
- [x] UI: per-record deletion with confirmation, Delete-now choice to remove or
  keep the iCloud backup, pending list with Retry and "Delete pending backups",
  honest erasure copy.
- [ ] Scoped and full Simulator evidence for Milestone 2 recorded in
  `Docs/verification-log.md`. Status: in progress.
- [ ] Real-container backup and deletion on the physical device. Status:
  operator manual (not executed); awaiting operator approval.

### Milestone 3: Release engineering, signing channel, composed E2E, docs, final matrix

- [x] Operator signing channel: `Configs/Operator.xcconfig` with
  `#include? "Operator.local.xcconfig"`, templates
  `Configs/Operator.example.xcconfig` and
  `Configs/RoomScanStudio.example-entitlements.plist`; local copies
  git-ignored.
- [x] `ITSAppUsesNonExemptEncryption` = false in
  `RoomScanStudio/Resources/Info.plist`; `PrivacyInfo.xcprivacy` unchanged.
- [x] Composed end-to-end UI test
  `RoomSlice7EndToEndUITests.testSlice7PersonalReleaseEndToEnd` in
  `RoomScanStudio/RoomScanStudioUITests/RoomSlice7EndToEndUITests.swift`.
- [x] Documentation set (this plan, privacy, iCloud setup, release checklist,
  device plan, known limitations, threat model, runbook note, export format,
  `Docs/compatibility-matrix.md`, README, acceptance skill note).
- [ ] Final full iPhone and iPad Simulator matrix. Status: in progress.
- [ ] Scoped device UI tests (isolated `--use-mock-fixture` /
  `--use-fake-cloud-backup` runs) on the iPhone 17 Pro. Status: awaiting
  operator approval.
- [ ] Signed Release archive inspected with `codesign -dvv`. Status: awaiting
  operator approval.
- [ ] TestFlight internal upload. Status: operator manual (not executed).
- [ ] Evidence record written at final acceptance.

## Acceptance clauses

1. Static structure: `python3 -B Scripts/verify_xcode_scaffold.py` and
   `python3 -B -m unittest discover -s Scripts -p 'test_*.py'` pass; results in
   `Docs/verification-log.md` and the evidence record.
2. Core: `swift test` passes, including
   the `RoomCloudBackupDeletionTests` Core suite
   and the local Trash store tests; count in the evidence record.
3. Unsigned build: the root `AGENTS.md` unsigned iOS build command succeeds;
   result in the evidence record.
4. Full schemes: the iPhone 16 Pro and iPad (10th generation) Simulator
   xcresults (iOS 26.3) each pass the complete `RoomScanStudio` scheme, bound by
   path and SHA-256 in the evidence record.
5. Composed scenario: `testSlice7PersonalReleaseEndToEnd` passes inside the
   full-scheme xcresults from clause 4.
6. Device (awaiting operator approval): scoped Trash, cloud backup and
   end-to-end UI tests pass in isolated `--use-mock-fixture` /
   `--use-fake-cloud-backup` device xcresults, bound in the evidence record.
   These are not LiDAR, Face ID or live-iCloud evidence.
7. Archive (awaiting operator approval): a signed Release archive and its
   `codesign -dvv` output are bound in the evidence record.
8. Records: the evidence record states that no TestFlight upload, App Store
   submission, CloudKit Production schema change, or hosted change was
   performed, and `Docs/verification-log.md` carries the dated entries.

## External gates not claimed

Real LiDAR capture, Face ID, live iCloud backup and deletion, CloudKit
Production schema deployment, TestFlight upload, App Store review, hosted
deployment, and physical erasure of CloudKit data are outside local acceptance.
The app cannot verify physical erasure of deleted CloudKit records.

## 2026-10-02 status

Clauses 6 and 7 were run with operator approval and are bound in the
2026-10-02 reconciliation of
`Docs/evidence/2026-10-01-ai-redesign-slice-7-personal-release.md`: the scoped
device UI tests passed on the iPhone 17 Pro, and a development-signed Release
archive was built and inspected without export. The device run found a
production storage defect (system `/var` link rejected by six ancestor
walkers), now fixed with tests and mutation controls. Clauses 1–5
were rerun on the final tree and passed: scaffold, Python (89 tests), Core
(366 tests), the unsigned build, and both full Simulator schemes (412 total,
411 passed, 0 failed, 1 skipped on each, with the end-to-end test passing in
both). The external gates above remain unclaimed.
