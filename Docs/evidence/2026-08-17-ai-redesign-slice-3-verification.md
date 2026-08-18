# AI Redesign Platform — Slice 3 Verification Evidence

**Date:** 2026-08-17
**Scope:** Slice 3 only — AI Room Package, disclosure review, Share Sheet
lifecycle, and Concept Sets
**Status:** local implementation and local/Simulator verification complete;
physical-device and real-provider gates remain open

## Claim boundary

This worktree implements the approved local/offline Slice 3 boundary only. It
does not start Slice 4, provision an account or hosted service, call a model or
provider, upload room data, insert into provider chat, add billing, publish a
portal, or change any external system.

The supported physical LiDAR iPhone was unavailable. Physical iPhone Share
Sheet/import behavior is therefore not claimed. Physical iPad remains waived
and unverified. Real-provider behavior, current privacy/account terms,
instruction following, and output quality are also unverified.

The work remained unstaged and uncommitted on
`agent/ai-redesign-platform-slice3` at
`fa864d39ee230cfaa6994dec1574e344770556a9`, which is also the merge base. The
primary checkout remained a separate worktree.

## Implemented local boundary

- Core owns source-bound artifact slots/plans, canonical plan and selection
  digests, complete ledgers, AI-ready/Complete validation, deterministic ZIP32
  STORE construction and independent extraction, Concept Set/archive
  contracts, atomic store/review, and immutable-source checks.
- The app owns exact source materialization, floor/six-view derivatives,
  bounded reference selection, metadata-stripping image re-encoding, advisory
  sensitive-content analysis, single-use disclosure, typed Share Sheet
  cleanup, bounded untrusted import, and finalized-package provenance for
  automatic Concept mapping. The production `AIRedesign` path has no
  provider/model/auth/direct-HTTP client.
- SwiftUI exposes profile, brief and feature permissions, readiness, selected
  and Complete-raw previews/metadata, advisories, precise-GPS exclusion,
  external-provider notice/acknowledgement, exact approval, share state,
  Concept import/mapping/comparison/reopen/archive/delete, and retryable cleanup
  errors.

## Final local verification matrix

| Oracle | Final observed result | Retained evidence |
| --- | --- | --- |
| Full Core | `swift test --disable-sandbox --quiet`: 266/266 passed, zero failures, 2026-08-17 22:25 BST | terminal result; focused archive suite also passed 7/7 |
| Complete iPhone scheme | 219/219 passed, zero failures/skips on iPhone 16 Pro, iOS 26.3.1 (185 app + 34 UI) | `/private/tmp/RoomScanStudio-Slice3-final-scheme-iphone-v1.xcresult` |
| Complete iPad scheme | 219/219 passed, zero failures/skips on iPad (10th generation), iOS 26.3.1 (185 app + 34 UI) | `/private/tmp/RoomScanStudio-Slice3-final-scheme-ipad-v1.xcresult` |
| Final Slice 3 iPhone UI | 5/5 passed, zero failures/skips; serialized after fixture appearance/gesture hardening | `/private/tmp/RoomScanStudio-Slice3-final-ui-iphone-v6.xcresult` |
| Final Slice 3 iPad UI | 5/5 passed, zero failures/skips; serialized after fixture appearance/gesture hardening | `/private/tmp/RoomScanStudio-Slice3-final-ui-ipad-v6.xcresult` |
| Production package/Concept/share integration | 7/7 passed, including finalized-package provenance reload, automatic/manual/unmatched mapping, AI-ready/Complete closure, and share cleanup | `/private/tmp/RoomScanStudio-Provenance-FinalApp/Logs/Test/Test-RoomScanStudio-2026.08.17_03-32-05-+0100.xcresult` |
| Unsigned generic-Simulator build | `xcodebuild build ... CODE_SIGNING_ALLOWED=NO` exited 0 | `/private/tmp/RoomScanStudio-Slice3-final-unsigned-build` |
| Slice 3 static structure | direct Slice 3 checker returned `[]`; all in-memory mutation controls returned `[]`; simulator selector self-test passed; PBX plist lint returned `OK` | terminal results on 2026-08-17 |
| Full static verifier | one known, pre-existing exception only: `forbidden active signing/cloud setting: DEVELOPMENT_TEAM` | intentionally preserved; not counted as a Slice 3 pass |

The complete 219-test scheme bundles preceded only test-fixture appearance and
gesture-timing hardening. The final five-test UI bundles and unsigned build
compile and exercise the final tree after those changes. No production package,
Concept, disclosure, archive, or share behavior changed between those matrices.

The build emitted existing warnings in non-Slice-3 capture/editor/cloud/test
code, including deprecated `onChange`, a CloudKit account-status exhaustiveness
warning, unnecessary `nonisolated(unsafe)`, an async enumerator warning, an
unused validation result, and older test concurrency warnings. This report does
not claim a warning-free target.

## Archive, disclosure, and source closure

`RoomAIRoomPackageTests.testArchiveIsDeterministicCanonicalStrictAndDoesNotMutateSources`
builds AI-ready and Complete twice, requires byte-stable canonical manifest and
archive results, independently extracts each archive, validates exact entry
closure and every included digest/byte count, verifies the outer archive
receipt, rejects a hidden entry, and proves source files remain unchanged. It
passed in the final 7/7 focused package suite and the final 266/266 Core run.

The app production integration additionally finalized and independently opened
real app-materialized AI-ready and Complete archives. Disclosure approval is
single-use and bound to exact source revision, artifact plan, selection, and
the actual reviewed raw-image set. AI-ready structurally has no raw slots;
Complete may include raw only when the exact reviewed set and consent agree.
Both profiles exclude world maps and precise GPS.

Concept automatic mapping is authorized only by a canonical manifest retained
from an independently finalized local package and by a camera declared in both
that package and the current orientation. Recreated models reload that binding.
A forged package, wrong source/package/camera, and an ancestor-symlinked
provenance root fail closed; manual or unmatched imports remain available.

## Red-green and live-guard controls

All mutation windows were restored before the final matrices. The retained
result bundles are disposable local/Simulator fixtures; no authoritative room
or external system was changed.

| Boundary | Observed red/control | Restored green |
| --- | --- | --- |
| Complete raw preview, valid Complete-without-raw, forced replacement | old production paths failed the focused additions in `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/review-gaps-red.xcresult` | four focused tests passed in `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/review-gaps-restored.xcresult` |
| Exact raw disclosure closure | old coordinator accepted included raw RGB absent from the reviewed set in `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/raw-disclosure-red.xcresult`; weakening the live equality guard failed in `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/raw-disclosure-mutation.xcresult` | guard restored in `review-gaps-restored.xcresult` |
| Forced replacement reservation | neutralizing the live reservation reselected the old higher-ranked candidate and failed `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/replacement-selection-mutation.xcresult` | restored in `review-gaps-restored.xcresult` |
| Capture evidence containment | traversal, intermediate symlink, oversized frame, depth/confidence traversal, and bundle-symlink probes failed 6 expected cases in `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/capture-hardening-red.xcresult`; disabling leaf/containment guards failed all three traversal controls in `capture-hardening-mutation.xcresult` | 13/13 passed in `capture-hardening-restored.xcresult`; 48/48 capture consumers passed in `capture-hardening-consumers.xcresult` |
| Package lifecycle/stale work | live cleanup/generation mutation failed in `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/lifecycle-mutation.xcresult` | suspended prepare/finalize/discard and exact cleanup paths passed in `lifecycle-restored.xcresult` |
| Durable Concept provenance | a valid finalized-package automatic import failed before persistence in `/private/tmp/RoomScanStudio-Slice3-retained-xcresults/concept-provenance-red.xcresult`; an ancestor symlink wrote through before the guard in `provenance-ancestor-red.xcresult`; removing claimed-package equality made `RoomConceptSetTests/testAutomaticMappingRequiresExactValidatedSourcePackageBinding` fail 1/1 | first durable green in `concept-provenance-first-green.xcresult`; ancestor control green in `provenance-ancestor-green.xcresult`; restored Core Concept suite 17/17 and app integration 7/7 |
| Required structural mutations | in-memory sources weaken confirmed/manual orientation, exact disclosure plan and selection, AI-ready raw exclusion, GPS/world-map exclusion, archive entry closure, Concept source/capability/promotion, production HTTP-client exclusion, Share Sheet cleanup, and provenance ancestor isolation | `verify_memory_only_negative_controls` returned `[]`; the direct Slice 3 checker also returned `[]` |

Representative restored commands were:

```text
swift test --disable-sandbox --filter RoomAIRoomPackageTests
swift test --disable-sandbox --filter RoomConceptSetTests
xcodebuild test ... -only-testing:RoomScanStudioTests/RoomAIRedesignProductionIntegrationTests
xcodebuild test ... -only-testing:RoomScanStudioTests/RoomAIRoomPackageServiceTests
python3 -B Scripts/verify_xcode_scaffold.py
```

The full verifier command intentionally exits nonzero on the preserved
`DEVELOPMENT_TEAM` setting; the independently invoked Slice 3 checker and
mutation self-controls are the clean Slice 3 results.

## Screenshot and accessibility evidence

The final serialized UI bundles yielded 13 PNG attachments per form factor:

- `Docs/evidence/2026-08-17-ai-redesign-slice-3-screenshots/iphone`
  contains 13 portrait PNGs at 1206×2622 plus its xcresult attachment manifest.
- `Docs/evidence/2026-08-17-ai-redesign-slice-3-screenshots/ipad` contains 13
  portrait PNGs at 1640×2360 plus its xcresult attachment manifest.
- `Docs/evidence/2026-08-17-ai-redesign-slice-3-screenshots/SHA256SUMS`
  records and successfully rechecks every retained PNG and both manifests.
  Manifest digests are
  `6397c4847187e291772d68af61c7ca83204d46c617cf8d255284f676a2f66ae6`
  (iPhone) and
  `251aa15207cae76f65d6849e82120adfb90bae49af9f92a4762ae898c65afd09`
  (iPad).

The set covers light/default Dynamic Type package and Concept flows, actual
selected-image review/advisory text, Complete approval/share readiness,
automatic/manual/unmatched mapping, original-versus-concept comparison,
archive/delete confirmation, accessibility XXXL disclosure/import actions,
genuine adaptive dark profile/comparison screens, and an explicit readiness
failure with preparation blocked.

Manual contact-sheet review found the critical actions visible and readable on
both form factors. Accessibility XXXL intentionally requires scrolling but the
tested actions remain hittable. An earlier optional landscape capture left
unused black space and was rejected. An initial dark launch default was also
rejected when its screenshot hash matched light mode; the final fixture applies
the SwiftUI color scheme explicitly, and both focused dark controls and final
five-test classes passed. The two iPad Concept screenshots numbered 04 and 05
are pixel-identical because the tall viewport already showed the retained
gallery reference before the simulated loose import; the import, publication,
mapping, reopen, and subsequent manual-state change are independently asserted
by the UI and coordinator tests.

## Built-artifact inspection

The final artifact is
`/private/tmp/RoomScanStudio-Slice3-final-unsigned-build/Build/Products/Debug-iphonesimulator/RoomScanStudio.app`.

- Build result: exit 0; bundle size 56 MiB; bundle identifier
  `org.roomscanstudio.app`; minimum OS 18.0; iPhone and iPad device families.
- Launcher Mach-O: universal x86_64/arm64;
  SHA-256 `fa70d02bfee465a8440bcc6227c722a80cca94bbe242e1b1c7e26521d1a8c038`.
- Debug implementation dylib: universal x86_64/arm64;
  SHA-256 `0eecb393a430cd17729e810c8bca97d4f73eaa7a8f7231d9905ee431669311cf`.
- The built implementation contains `RoomAIRoomPackage`, `RoomConceptSet`,
  `RoomAIRedesignHostView`, `SystemShareSheet`, `AIRedesignProvenance`, the
  Concept import accessibility ID, and the deterministic dark-fixture flag.
- Linked frameworks include the expected local Apple ImageIO, CoreGraphics,
  Vision, and UniformTypeIdentifiers boundaries; artifact inspection found no
  provider/model SDK introduced by Slice 3.
- With `CODE_SIGNING_ALLOWED=NO`, Xcode's Simulator linker still emitted an
  ad-hoc linker signature. `TeamIdentifier` is absent and resources are not
  sealed; this is not a distribution signing claim.

## Final repository checks

- `git diff --check`: passed.
- `git diff --cached --quiet`: passed; the staged diff is empty.
- Branch/HEAD/merge base:
  `agent/ai-redesign-platform-slice3` /
  `fa864d39ee230cfaa6994dec1574e344770556a9` /
  `fa864d39ee230cfaa6994dec1574e344770556a9`.
- `plutil -lint RoomScanStudio.xcodeproj/project.pbxproj`: `OK`.
- `python3 -B Scripts/select_simulators.py --self-test`: passed.
- Slice 3 direct static checker: `[]`.
- In-memory negative controls: `[]`.
- Full static verifier: only the known `DEVELOPMENT_TEAM` exception.
- No staging, commit, push, provider request, upload, or other external action
  occurred.

## Remaining non-simulator proof

The physical protocol in `Docs/real-device-test-plan.md` remains required for
real Share Sheet targets, Files/AirDrop/external-app handoff, security-scoped
imports, completion/cancellation/error/dismissal behavior, lease cleanup, and
source-immutability confirmation on the supported LiDAR iPhone. Physical iPad
remains waived and unverified.

External-provider behavior is also unverified. Slice 3 only writes local
provider-tailored instruction files; it makes no claim about current provider
capabilities, privacy/account terms, instruction following, or output quality.
