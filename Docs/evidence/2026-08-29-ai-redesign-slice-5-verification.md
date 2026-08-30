# Slice 5 migration, immutable sync, conflicts, and storage verification — 2026-08-29

## Final status

Slice 5 is locally complete against the approved outcome:

> Provide recoverable cross-device professional projects without multi-master
> data loss.

The final evidence was started from clean local `main` at
`ee102b28a3f486848624fe005a66d4a4d43056e1`, which remains intentionally one
commit ahead of `origin/main`. No reset, rebase, commit, push, pull request,
deployment, provider mutation, credential use, or customer data was involved.

| Boundary | Local result | Evidence |
| --- | --- | --- |
| Core archive, raw-redaction, companions, and recovery | **PASS** | 304/304 Swift package tests; real deterministic ZIP/package fixtures; package-first and companion-resume crash oracles |
| iOS app migration, journal, offline drafts, conflicts, recovery, and raw review | **PASS** | 244 app tests within each full scheme; two real local client roots; real Core archives and stores |
| Hosted HTTP/service/worker | **PASS** | 304/304 Node service tests; strict typecheck and build; exact 19-route Slice 4 and 29-route Slice 5 manifests |
| PostgreSQL 16 schema, CAS, RLS, authorization, quotas, and leases | **PASS** | PostgreSQL 16.13 fresh/staged/full integration; two authenticated logical clients; 9/9 guard mutations detected and restored |
| Offline infrastructure composition | **PASS (synthetic)** | 110/110 local tests, typecheck, synth/inspection, 32/32 policy mutations, retained Slice 4 umbrella |
| iPhone and iPad full schemes | **PASS** | 282/282 unique tests on each destination, above the prior 259 baseline |
| Generic unsigned iOS delivery artifact | **PASS** | Build succeeded; required Slice 5 symbols present; `lastWriterWins` and `roomscan-slice6` absent with a positive detector control |
| Responsive visual evidence | **PASS** | Nine reviewed screenshots: iPhone portrait, iPad portrait, and 1180×820 desktop-width migration/raw/conflict states |
| Live provider, physical device, and deployment | **NOT VERIFIED / NOT PERFORMED** | Explicit release gates below |

The freshness marker is
`.artifacts/slice5-final-2026-08-29/run-marker.json`; its start time is
`2026-08-29T15:07:05.588893+00:00` and its bound HEAD is exactly `ee102b2`.
The final aggregate report is
`.artifacts/slice5-final-2026-08-29/slice5-sync/verification.json` and records
all eight completion clauses as `PASS`.

## What changed and why

### Core and local persistence

- Added strict, versioned initial migration, expected-head append, working-set,
  separate raw-attachment, conflict, lease, and recovery contracts.
- Added a deterministic professional working-set archive around the existing
  validated room-package backup boundary. The default archive closes over the
  package, redesign/orientation, Concept Sets and their attachments, and only
  exact canonical AI-ready Room Package provenance needed by included
  automatic mappings.
- Added an external raw-redacted package materializer. It rewrites only the
  copied manifest's world-map policy, omits that file, validates the result,
  and leaves the live package byte-for-byte unchanged.
- Added a separate accepted-review-bound raw archive for RGB, depth,
  confidence, diagnostics, and supported raw-only artifacts.
- Added staged inspection and package-first recovery. Downloads derive their
  complete local descriptor from the digest-bound strict manifest, call the
  existing prepare/commit boundary, then idempotently promote companions.
  Recover-as-copy uses store-derived destination bindings and reports any
  automatic-to-manual Concept mapping downgrade rather than inventing package
  provenance.

### App and UX

- Added a professional-only atomic journal, lazy transport, explicit migration
  preview/approval/progress/exact retry, offline-draft detection, lease calls,
  status reconciliation, preserved-branch comparison, rebase-as-copy,
  duplicate-locally, second-device recovery, and separate raw review.
- Preserved local save as the source of truth. Launch, foreground, save, and
  offline transitions do not upload. A local edit becomes an immutable pending
  draft until an explicit professional sync command.
- Kept `ProfessionalEnvironmentFactory.defaultOff()` inert. Guest scan, save,
  view, edit, export, import, AI-package, Concept Set, and Share Sheet flows
  construct no hosted client and remain account-free/offline.
- Added deterministic, DEBUG/simulator-only migration, conflict, and raw-review
  fixtures plus accessibility identifiers and iPhone/iPad/desktop-width tests.
  Private CloudKit backup remains visibly and technically separate.

### Hosted service and storage

- Preserved the frozen Slice 4 v3 19-route manifest and added the sealed Slice
  5 v1 manifest with exactly 10 project-sync routes, for 29 total.
- Added transaction-bound project/revision/upload capabilities, post-commit
  provider effects, immutable presigned quarantine allocation, durable
  completion, targetless worker wake/recovery, exact-version validation,
  unique active promotion, public-only status/recovery results, separate raw
  configuration/attachment, and advisory 900-second edit leases.
- The validator exercises the real Core-created golden archives and rejects
  traversal, collision, symlink/non-STORE, CRC, closure, digest, size,
  project/head/epoch, nested package, and forbidden-raw variants. The worker
  has a unified 64 MiB archive ceiling verified under its configured runtime
  memory limit.

### PostgreSQL and authorization

- Added forward-only `0008_professional_project_sync.up.sql` with immutable
  revisions and object versions, durable uploads, idempotency declarations,
  quota reservation/finalization/release, raw attachments, preserved stale
  branches, recovery lookup, audit, and bounded leases.
- Finalization validates/promotes before one expected-head compare-and-swap.
  Exactly one concurrent append can become canonical; a stale append retains
  its revision and immutable active version for download.
- All five new tenant tables force RLS. The API and credential-backed worker
  roles remain `LOGIN NOINHERIT`, non-owner, non-superuser, without
  `BYPASSRLS` or membership edges, and receive only reducer capabilities.
  Same-tenant positive controls accompany cross-tenant denials.

### Infrastructure and operations

- Added an encrypted/versioned/private project-sync object tier, encrypted
  validation queue and DLQ, five-attempt redrive, bounded visibility timeout,
  targetless recovery schedule, worker Lambda/runtime credential, exact-prefix
  S3 and KMS/Data API/SQS permissions, CloudTrail data events, alarms, and
  non-sensitive outputs.
- Pinned migration `0008` into every migration-manifest/digest seam and proved
  staged `0001`–`0007` upgrade applies only the additive migration.
- Added operational disable/recovery guidance. Rollback denies new writes and
  stops worker triggers while keeping authorized recovery reads and all local
  truth available; it performs no down migration or object deletion.

## Compatibility and exclusions

- Existing local package v1/v2, `RoomProjectBackupArchive`, frozen
  `roomscan-working-project-sync-v1`, Slice 4 service routes, and private
  CloudKit semantics remain readable and unchanged.
- Initial hosted migration is a distinct null-head contract, not a sentinel
  expected head. Raw attachment is a separate contract and storage/quota tier.
- No geometry merge, CRDT/OT, last-writer-wins, background local-save upload,
  launch-time sync, automatic migration, Slice 6 publication/portal route, or
  Slice 7 resource/operations product feature was added.
- Production quota values, prices, retention/lifecycle policy, and live
  provider limits remain gated; local verification uses only the existing
  explicit test policy and synthetic provider configuration.

## Exact completion oracle and results

### Fresh component matrix

```sh
PATH=/Users/philipnora/.nvm/versions/node/v24.15.0/bin:$PATH \
python3 -B Scripts/verify_slice5_sync.py \
  --artifacts-dir .artifacts/slice5-final-2026-08-29/slice5-sync
```

Result: **PASS**. The report records Node v24.15.0, PostgreSQL 16.13,
`client-a` and `client-b`, 304/304 Swift tests, all six fixed crash cuts,
the injected forbidden-raw positive control, clean default working storage,
accepted separate raw storage, and clauses 1–7 `PASS`. Its nested commands
also passed:

```text
python3 verifier self-tests                         PASS
swift test --package-path .                        304/304
npm --prefix HostedService run typecheck           PASS
npm --prefix HostedService test                    304/304
npm --prefix HostedService run build               PASS
PostgreSQL 0008 two-client integration             PASS
PostgreSQL 0008 security integration               PASS
staged 0001–0007 -> 0008 upgrade                   PASS
npm --prefix HostedService/infra run typecheck     PASS
npm --prefix HostedService/infra run test:local    110/110
```

The database concurrency summary is:

```text
logical_clients=2 canonical_appends=1 stale_appends=1
preserved_branches=2 raw_head_moves=0 lease_seconds=900
initial_shell_before_validation=0 reaped_allocations=1 status=pass
```

The security summary records two runtime roles, five forced-RLS tables,
5 worker ACL controls, 11 API ACL controls, three cross-tenant denials with a
same-tenant positive control, and public/internal identifier controls.

### Guard-neutralization and negative controls

```sh
PATH=/Users/philipnora/.nvm/versions/node/v24.15.0/bin:$PATH \
python3 -B Scripts/verify_slice5_mutation_controls.py \
  --artifacts-dir .artifacts/slice5-final-2026-08-29/slice5-mutations
```

Result: **PASS**. Nine database guards and 32 infrastructure guards were each
neutralized in isolated copies, detected by a failing focused oracle, restored,
and rerun green. Database mutations include the expected-head CAS,
targetless claim, forced RLS, source binding, raw-target uniqueness/status,
opaque version schema/input, and unified 64 MiB ceiling. Infrastructure
mutations include encryption, public-access/TLS/version retention, DLQ/redrive,
schedule/wake binding, exact-prefix IAM, KMS isolation, CloudTrail data events,
alarms, and migration/provider invariants. `detected == restored` for both
inventories.

The real working-set validator also found an intentionally injected forbidden
raw artifact before accepting the clean Core fixture, while the same reviewed
raw class succeeded in its separate archive. The compiled-artifact inspector's
positive control found an injected forbidden marker before accepting the real
app. No negative claim depends on an unexercised detector.

The staged recovery guard was exercised against recomputed corrupt package and
companion entries: neutralizing pre-live acceptance makes the focused
no-live-mutation oracle fail; the restored strict prepare boundary rejects the
transaction and the valid package-first recovery control passes. The raw-path,
manifest-digest, route/action, lazy guest transport, journal, and conflict
tests were likewise first observed red before their implementation and then
green. Important development reds included:

- missing Core/app/service/DB/infra contract surfaces before implementation;
- recover-as-copy initially using the wrong source identity;
- lost-journal retry initially failing to acknowledge the canonical hosted
  head;
- expiry and raw-review boundary-time errors;
- conflict action accessibility and asynchronous comparison state;
- the screenshot recorder rejecting repeated passing attachments before
  highest-repetition selection was added.

The retained mutation logs are under
`.artifacts/slice5-final-2026-08-29/slice5-mutations/`. The early compile/test
reds above were observed during the red-green loop; not every early compiler
transcript was retained as a separate artifact, so this record does not claim
otherwise.

### Slice 4 regression and full hosted/database/infra matrix

```sh
PATH=/Users/philipnora/.nvm/versions/node/v24.15.0/bin:$PATH \
python3 -B Scripts/verify_slice4_hosted.py \
  --artifacts-dir .artifacts/slice5-final-2026-08-29/slice4-hosted
```

Result: **PASS**, 13/13 steps. It reran the full service, PostgreSQL 16,
infrastructure assertions/mutations/synth, guest/secret scanners and positive
controls, generated a 147-file artifact manifest, and passed the artifact
secret scan. This is the Slice 4 verifier against the Slice 5 worktree, not a
historical result.

### Full iPhone scheme

```sh
xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=B8FBE9EA-81AD-4134-BC1D-A67A7747271E' \
  -derivedDataPath /private/tmp/roomscan-slice5-final-matrix-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath /private/tmp/roomscan-slice5-final-iphone-20260829.xcresult \
  test CODE_SIGNING_ALLOWED=NO
```

Result on iPhone 16 Pro / iOS 26.3.1 Simulator: **282/282 unique tests,
0 failed, 0 skipped**. This consists of 244 app tests and 38 UI tests. The 18
Slice 5 app-sync tests, package-first recovery test, four Slice 5 UI tests, and
guest regressions passed.

### Full iPad scheme

```sh
xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=FDDEC0DB-DB75-4FBA-8344-69E2A2819531' \
  -derivedDataPath /private/tmp/roomscan-slice5-final-matrix-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -retry-tests-on-failure -test-iterations 3 \
  -test-repetition-relaunch-enabled YES \
  -resultBundlePath /private/tmp/roomscan-slice5-final-ipad-r3-20260829.xcresult \
  test CODE_SIGNING_ALLOWED=NO
```

Result on iPad (10th generation) / iOS 26.3.1 Simulator: **282/282 unique
tests, 0 failed, 0 skipped**. The result contains 320 runs because bounded
retry was enabled. In the first UI iteration, two legacy taps timed out while
waiting on the host event loop and the landscape waiter timed out after already
capturing two states. The retry iteration passed all 38 UI tests; the same two
legacy tests plus the affected screenshot paths also passed focused controls.
No production-source change was made for those host timing events. App units
were 244/244 on the first run, and the landscape oracle measured the actual app
window at 1180×820.

### Desktop-width screenshot oracle

Visual inspection exposed an Xcode 26 evidence-capture defect:
`XCUIApplication.screenshot()` embedded a rotated portrait surface in a
landscape canvas, while `XCUIScreen` retained encoded portrait pixel order.
The UI itself had already passed the independent 1180×820 window-frame oracle.
The test attachment now rasterizes UIKit's encoded image orientation into
ordinary landscape pixel order, and this focused current-source run passed:

```sh
xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=FDDEC0DB-DB75-4FBA-8344-69E2A2819531' \
  -derivedDataPath /private/tmp/roomscan-slice5-final-matrix-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath /private/tmp/roomscan-slice5-final-desktop-screenshots-r3-20260829.xcresult \
  -only-testing:RoomScanStudioUITests/RoomScanStudioUITests/testSlice5DesktopWidthLandscapeScenarios \
  test CODE_SIGNING_ALLOWED=NO
```

Result: **1/1 passed**. The final screenshot recorder selected the latest
passing repetition when bounded retries exist and rejected ambiguous
duplicates. Current-source portrait captures were also rerun independently on
both form factors:

```sh
xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=40F0002D-4DC1-44C6-A9B9-5359F9F4D357' \
  -derivedDataPath /private/tmp/roomscan-slice5-final-matrix-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath /private/tmp/roomscan-slice5-final-iphone-screenshots-current-20260829.xcresult \
  -only-testing:RoomScanStudioUITests/RoomScanStudioUITests/testSlice5MigrationScreenshots \
  -only-testing:RoomScanStudioUITests/RoomScanStudioUITests/testSlice5RawArchiveScreenshots \
  -only-testing:RoomScanStudioUITests/RoomScanStudioUITests/testSlice5ConflictScreenshots \
  test CODE_SIGNING_ALLOWED=NO

xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=FDDEC0DB-DB75-4FBA-8344-69E2A2819531' \
  -derivedDataPath /private/tmp/roomscan-slice5-final-matrix-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath /private/tmp/roomscan-slice5-final-ipad-screenshots-current-20260829.xcresult \
  -only-testing:RoomScanStudioUITests/RoomScanStudioUITests/testSlice5MigrationScreenshots \
  -only-testing:RoomScanStudioUITests/RoomScanStudioUITests/testSlice5RawArchiveScreenshots \
  -only-testing:RoomScanStudioUITests/RoomScanStudioUITests/testSlice5ConflictScreenshots \
  test CODE_SIGNING_ALLOWED=NO
```

Results: **3/3 passed on iPhone** and **3/3 passed on iPad**.
Nine PNGs and their hashes are bound by
`.artifacts/slice5-final-2026-08-29/slice5-sync/screenshot-review.json`.
Manual review covered hierarchy, Dynamic Type behavior, contrast, VoiceOver
labels/order, touch targets, overflow, and safe areas. Screenshot inspection
proves the visual dimensions; XCTest assertions prove labels/order and
hittability.

### Generic unsigned build and delivered artifact

```sh
xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/roomscan-slice5-final-generic-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build

python3 -B Scripts/inspect_slice5_ios_artifact.py \
  --app /private/tmp/roomscan-slice5-final-generic-derived/Build/Products/Debug-iphoneos/RoomScanStudio.app \
  --output .artifacts/slice5-final-2026-08-29/slice5-sync/ios-artifact-inspection.json
```

Result: **BUILD SUCCEEDED / inspector PASS**. All contract, journal, conflict,
raw-review, action and professional-auth markers are present. The forbidden
`lastWriterWins` and `roomscan-slice6` markers are absent after a positive
control. Principal image digests are:

```text
6f2da121b084d3a0e4da81b687a0d1d008e3e65ef7e17a968f8a7c84db8576a0  RoomScanStudio
6803ac41b7a570d76bef660456c2194aa9127e1fd9c4b28e1d68dff4bc28091c  RoomScanStudio.debug.dylib
```

### Final static and aggregate proof

```sh
python3 -B -m unittest discover -s Scripts -p 'test_*.py'
git diff --check

python3 -B Scripts/verify_slice5_sync.py --finalize \
  --run-marker .artifacts/slice5-final-2026-08-29/run-marker.json \
  --component-report .artifacts/slice5-final-2026-08-29/slice5-sync/component-verification.json \
  --mutation-report .artifacts/slice5-final-2026-08-29/slice5-mutations/mutation-verification.json \
  --slice4-report .artifacts/slice5-final-2026-08-29/slice4-hosted/verification.json \
  --artifact-report .artifacts/slice5-final-2026-08-29/slice5-sync/ios-artifact-inspection.json \
  --screenshot-report .artifacts/slice5-final-2026-08-29/slice5-sync/screenshot-review.json \
  --iphone-xcresult /private/tmp/roomscan-slice5-final-iphone-20260829.xcresult \
  --ipad-xcresult /private/tmp/roomscan-slice5-final-ipad-r3-20260829.xcresult \
  --output .artifacts/slice5-final-2026-08-29/slice5-sync/verification.json
```

Result: Python **46/46 passed**, `git diff --check` **PASS**, and the finalizer
**PASS**. The finalizer ran last, rejected stale/pre-marker evidence by design,
read both real xcresults, rechecked counts and required Slice 5 test names,
validated every report/screenshot digest, and recorded all eight completion
clauses `PASS`.

## Security, privacy, and data-loss state

- Hosted heads move only after exact-version archive validation, immutable
  active promotion/verification, and one expected-head CAS. Stale and canonical
  branches remain separately addressable and downloadable.
- Allocation, completion, worker claim, validation and finalization accept no
  caller-selected tenant, object key/version, authorization role, or validator
  decision. Upload capabilities are 300-second immutable conditional PUTs and
  are not project authorization.
- Leases use server time and a 900-second bound. They are advisory and never
  weaken authorization or CAS; offline drafts may be submitted later.
- Ordinary logs omit request bodies, filenames, object keys/versions, signed
  URLs, room bytes, tokens, free-form project text, GPS, and identifiers that
  are not approved audit subjects.
- Raw classes remain outside the default working tier. Raw enablement is an
  owner/recent-auth, size/category/privacy-reviewed separate attachment that
  cannot advance or block the hosted working head.
- Recovery downloads stage in marker-owned scratch, verify outer and manifest
  digests and exact closure, then call the existing package-validation and
  prepare/commit boundary. Corrupt input does not mutate live projects.

## Rollback and migration state

Migration `0008` is additive and forward-only. The rollback point is before
enabling Slice 5 writes: set global/workspace `hosted_operations_enabled`
false, stop the validation event source and targetless recovery schedule, and
deny allocation/completion/raw/lease writes. Authorized recovery reads remain
available. The migration, immutable rows, and quarantine/active versions stay
in place; there is no destructive down migration or runtime object deletion.
Every local package, draft, companion, export, guest workflow, and private
CloudKit backup remains usable.

## Remaining external gates

- Physical-device Face ID/passcode, protection-state transitions, and
  background transfer behavior are **NOT VERIFIED**.
- Live AWS S3 conditional/checksum/version/copy/KMS/presign semantics, SQS
  redrive/recovery, Lambda limits, Data API/Aurora contention, IAM propagation,
  CloudTrail, dashboards and alarms are **NOT VERIFIED**. Offline CDK proof is
  not provider proof.
- Provider credentials, DNS/email/Apple/Stripe integration, production quota,
  price/retention/lifecycle approval, deployment, release approval, and real
  customer-data validation were **NOT PERFORMED**.
- This work received self-review and executable mutation coverage, but no
  separately provisioned cross-model pass: **this got no cross-model pass**.

## Handoff

The worktree is deliberately uncommitted. With the final aggregate report
green and generated build outputs removed, it is ready for owner review and a
single scoped Slice 5 commit. Slice 6 should begin only after that review/commit
in a fresh session; none of its publication or portal scope belongs in this
tree.
