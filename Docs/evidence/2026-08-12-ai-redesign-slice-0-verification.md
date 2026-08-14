# AI redesign Slice 0 verification evidence

- Date: 2026-08-12
- Branch: `agent/ai-redesign-platform-plan`
- Baseline commit: `362c8cd862f38b1d159647d901ba75c6ef749efd`
- Scope: feasibility, inventory, versioned contracts, hosted-service ADR, and
  threat model only
- Production mutation: none; no service, account, credential, capability,
  entitlement, endpoint, upload, billing path, or database was created

## Workspace and baseline discipline

The original checkout was inspected before work began. Its seven pre-existing
modified files were recorded as user-owned and left untouched. Slice 0 work was
performed in a separate Git worktree created from the required baseline commit.
No repository-local `AGENTS.md` or `.agents/memory/MEMORY.md` exists in this
worktree, so the supplied global instructions are the only additional
repository doctrine and there was no project memory to apply. No file was
staged, committed, pushed, or provisioned.

The committed baseline did not initially satisfy its own documented clean
oracle. Its static verifier reported 20 stale or real mismatches, its Xcode
project contained a development-team identifier, the app masthead used a fixed
38-point user-facing font, and two existing iPhone UI checks failed because an
off-screen control was inspected before scrolling and a two-second save wait
expired. These were treated as baseline repairs rather than AI product work:

- the project no longer commits a development team;
- the display font uses semantic Dynamic Type;
- the static verifier now describes the checked-in iOS 18, package-resolution,
  RoomCaptureView-owned session, evidence-encoder, viewer-gesture, and
  responsive-layout contracts, with mutation checks for the revised rules;
- UI helpers wait for visible/hittable state and bound the existing real ZIP
  backup fixture with an explicit per-test execution allowance.

Focused reruns preserved the existing behavior while removing timing-only
failures. Retained result bundles include:

- iPad rescan recovery: 1 test, 0 failures,
  `/private/tmp/roomscanstudio-baseline-green-ipad-rescan.xcresult`;
- iPhone rescan recovery: 1 test, 0 failures, 49.514 seconds,
  `/private/tmp/roomscanstudio-baseline-green-iphone-rescan-final.xcresult`;
- iPad fake-CloudKit backup: 1 test, 0 failures, 72.244 seconds,
  `/private/tmp/roomscanstudio-baseline-green4-ipad-cloud-final.xcresult`;
- iPhone simulated capture cleanup: 1 test, 0 failures, 18.995 seconds;
- iPad simulated capture cleanup: 1 test, 0 failures, 31.736 seconds,
  `/private/tmp/roomscanstudio-baseline-green-ipad-simulated-close.xcresult`.

The fake CloudKit test substitutes the transport, not archive construction or
validation; its longer allowance is therefore not evidence of a network call.

## Contract red-green and guard evidence

The first focused contract test did not compile because the five new contract
families were absent. Subsequent red runs established the following missing or
incorrect behavior before the implementation was restored green:

- unsupported source package schemas were accepted;
- canonical JSON escaped `/`, causing five golden digest mismatches;
- outbound paths accepted control characters;
- Concept Set attachments lacked content identity;
- duplicate JSON members, including an escaped-name alias, were accepted;
- case aliases and non-ASCII path identities were accepted; and
- a filename-only portal AI-ready download could be described without a
  revision-bound package manifest.

The restored implementation rejects duplicate members before object
materialization, decodes typed contracts from the already validated tree,
restricts portable v1 paths to printable ASCII with case-folded uniqueness,
and validates a portal AI-ready download from the actual bounded ZIP. That ZIP
check binds the outer byte count/digest, exact manifest entry and digest,
AI-ready profile, source revision, revision-manifest digest, artifact plan,
selection digest, archive closure, and every included artifact path/digest/size.

Safe mutation controls were also run. Each mutation made its focused oracle
fail before the live guard was restored:

- neutralizing the AI-ready raw-evidence exclusion;
- weakening exact AI-ready and Complete artifact-slot closure;
- weakening exact working-set and raw-opt-in sync closure;
- permitting a private snapshot section;
- removing Concept Set attachment digest validation; and
- bypassing top-level typed decoding protection (compile-fail proof).

The final focused fixture suite covers valid local extension, hosted resource,
AI-ready, Complete, default sync, raw-opt-in sync, and portal snapshot vectors;
future/cross-kind/unknown/duplicate/path/revision/private/raw/GPS/world-map and
actual-archive negatives. Final counts are recorded in the mechanical oracle
section below.

## SDK feasibility evidence

The installed toolchain was inspected directly: Xcode 26.3 (build 17C529),
Swift 6.2.4, and the iPhoneOS 26.2 SDK. A minimal arm64 iOS 18 type-check imported
RoomPlan, ARKit, LocalAuthentication, and UIKit and exercised the declarations
needed by the approved design. Header and source inspection established:

- RoomPlan surface/object categories and transforms are available, but there is
  no canonical entry-position/direction field; that value remains app-owned and
  user-confirmed;
- AR camera pose, intrinsics, image resolution, frame depth/confidence, mesh
  reconstruction, and support checks are available;
- biometric-only and device-owner/passcode-fallback policies are distinct, and
  evaluation is asynchronous; and
- the Share Sheet supplies a completion handler but does not make a nil
  activity type proof of cancellation.

The detailed declaration/source record is in
`2026-08-12-ai-redesign-sdk-audit.md`. This is compile-time feasibility only.
It is not RoomPlan, LiDAR/ARKit, Face ID, Share Sheet, performance, privacy, or
device behavior evidence.

## Reviews

A contract review found and then verified fixes for top-level decoder bypass,
portable path identity, and Concept Set attachment content identity. A separate
security review found duplicate-member ambiguity, case/Unicode path aliases,
and filename-only portal package validation. After the fixes, its final result
was PASS with no remaining high- or medium-severity finding and 27 focused tests
green. These were separately provisioned same-family reviews, not a cross-model
pass.

## Final mechanical oracle

### Repaired baseline-only worktree

A detached worktree at exact commit
`362c8cd862f38b1d159647d901ba75c6ef749efd` contains only the baseline repairs
listed above. It has no `RoomRedesignContracts.swift`, redesign fixture corpus,
or redesign tests. This makes baseline behavior independently inspectable
rather than relying on the integrated tree:

- `python3 -B Scripts/verify_xcode_scaffold.py`: passed, including its
  memory-only negative controls;
- `python3 -B Scripts/select_simulators.py --self-test`: passed;
- `swift test --disable-sandbox` with task-local module caches: 178 tests,
  0 failures, 16.544 seconds;
- iPhone 16 Pro / iOS 26.3.1 Simulator full scheme: 145/145
  (120 app + 25 UI), 0 failures, xcodebuild exit 0,
  `/private/tmp/roomscanstudio-baseline-final-iphone.xcresult`;
- iPad (10th generation) / iOS 26.3.1 Simulator full scheme: 145/145
  (120 app + 25 UI), 0 failures, xcodebuild exit 0,
  `/private/tmp/roomscanstudio-baseline-final-ipad.xcresult`;
- package resolution exited 0 with MetalSplatter `2b965de1934de38dda1c71cf90bf798aa948a14c`,
  `spz-swift` 2.1.0, `swift-argument-parser` 1.8.2, and local
  `RoomScanCore`; and
- the fresh unsigned generic-device build at
  `/private/tmp/roomscanstudio-baseline-final-device-derived` exited 0 with
  `BUILD SUCCEEDED`, 0 errors, and no redesign source, object, or linked symbol.

The required source-state separation is proved, but the literal chronology
needs to remain explicit: commit `362c8cd` was not green when first inspected,
and the repaired baseline matrix was completed retrospectively in this
detached worktree after the failures were diagnosed. This record does not
rewrite that sequence into a claim that the initially broken baseline had
passed earlier in wall-clock time.

### Slice 0 contract and offline oracles

Commands were rerun against the completed integrated worktree:

```sh
python3 -B Scripts/verify_xcode_scaffold.py
python3 -B Scripts/select_simulators.py --self-test
swift test --disable-sandbox --filter RoomRedesignContractFixtureTests
swift test --disable-sandbox
xcrun swiftc -module-cache-path /private/tmp/roomscanstudio-sdk-probe-cache \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk \
  -target arm64-apple-ios18.0 -typecheck /private/tmp/apple_sdk_probe.swift
git diff --check
```

Observed results:

- static structure passed; its production-source guest-boundary scan found no
  HTTP/auth/hosted client, and an in-memory injected `URLSession` made that
  oracle fail as intended;
- simulator selector self-test passed;
- focused redesign fixtures: 27 tests, 0 failures, 0.425 seconds;
- complete portable package: 205 tests, 0 failures, 17.424 seconds;
- installed-SDK type-check: exit 0; and
- final whitespace/diff check: exit 0.

The current executable guest route also has an in-process iPhone Simulator
integration oracle. It bootstraps the real `AppEnvironment`, completes
simulated capture and explicit Save, loads and appends a local edit, prepares
the actual legacy head export, and cleans its lease. It passed 1/1 in 0.807
seconds at
`/private/tmp/roomscanstudio-guest-offline-final.xcresult`. A deliberately
injected `.invalid` HTTP request was caught and failed by the explicitly
configured test transport. Global `URLProtocol.registerClass` did not intercept
new default or ephemeral sessions on this Simulator; both experimental
controls reached `.invalid` DNS and returned `cannotFindHost`. The independent
production-source oracle therefore closes that instrumentation bypass. Future
AI-package construction, Concept Set import, and a physical Share Sheet remain
unexercised and are not claimed by this result.

### Integrated Xcode and delivery matrix

The completed worktree passed the full scheme independently on both form
factors with 60-second default and 150-second maximum test timeouts:

- iPhone 16 Pro / iOS 26.3.1 Simulator: 146/146
  (121 app + 25 UI), 0 failures/skips/expected failures, xcodebuild exit 0,
  `/private/tmp/roomscanstudio-ai-redesign-final4-iphone.xcresult`;
- iPad (10th generation) / iOS 26.3.1 Simulator: 146/146
  (121 app + 25 UI), 0 failures/skips/expected failures, xcodebuild exit 0,
  `/private/tmp/roomscanstudio-ai-redesign-final4-ipad.xcresult`.

An earlier full iPhone control recorded 144/145 because the existing metadata
lifecycle completed in 64.096 seconds under a generic 60-second allowance. It
also exposed a transient second-app termination in the save/discard test. The
harness now uses an explicit 120-second allowance for the deliberately long
lifecycle and one app process for save/discard. The focused repair passed 2/2
(69.098 and 26.033 seconds), and both final full matrices above passed. Runs
interrupted after later evidence changes were retained as superseded and were
not counted; their actual xcodebuild images and children exited and orphan
checks found no remaining xcodebuild, xctest, or RoomScanStudio process.

Final integrated package resolution exited 0 with the exact pins listed for
the baseline. A fresh unsigned generic-device build at
`/private/tmp/roomscanstudio-ai-redesign-final-device-derived` exited 0 with
`BUILD SUCCEEDED` and 0 errors. The compiler Swift file list contains
`RoomRedesignContracts.swift`, a `RoomRedesignContracts.o` exists, and the
linked product contains representative `RoomAIRoomPackage.validate()`,
`RoomPortalBranding.validate()`, `RoomPortalSnapshot`, and
`RoomRedesignScope` symbols. The detached baseline provides the negative
artifact control. Generic builds emitted nine known warnings (seven existing
source/compiler categories plus AppIntents metadata and interface-orientation
validation); full test builds emitted those categories plus test-only Swift 6
captured-variable warnings. No warning is treated as device/service proof.

Initial direct SwiftPM/SDK/package-resolution retries inside the outer file
sandbox failed because the toolchain tried to write user-level module and
manifest caches. The recorded successful SwiftPM and SDK commands use
task-local caches (and SwiftPM `--disable-sandbox`); Xcode resolve/build/test
commands ran sequentially through the Xcode verification lane. These failures
were environment/cache errors, not silently counted as passing commands.

The original checkout was inspected again after verification. It remains on
`main` with the same seven user-owned modified files recorded at kickoff. No
Slice 0 file was staged, committed, pushed, provisioned, or transmitted.

## Open limitations and blocked evidence

- No representative hosted operating trace exists because Slice 0 is forbidden
  from provisioning or transmitting data. The ADR uses explicit repository
  observations and labeled workload assumptions; production pricing, quotas,
  protected-portal delivery cost, and retention performance remain blocked on
  representative measurements and the required operator/vendor spikes.
- No physical LiDAR iPhone or iPad was attached. RoomPlan category behavior,
  coordinate conventions, depth/confidence availability, registration, capture
  health, performance, and thermal behavior remain open.
- No real Face ID/passcode matrix was exercised.
- No physical Share Sheet destination, cancellation, error, dismissal, or
  lease-cleanup behavior was exercised.
- The current executable guest route is covered through legacy export
  preparation and cleanup. AI-package construction and Concept Set import are
  future Slice 3 implementations, so Slice 0 cannot yet execute them offline.
- No hosted identity, tenant isolation, upload, immediate revocation, deletion,
  restore, audit, email, Apple federation, or billing behavior exists to test in
  this slice.

Those gates remain unchecked in `Docs/release-checklist.md` and have concrete
protocols in `Docs/real-device-test-plan.md` and the hosted-service ADR.
