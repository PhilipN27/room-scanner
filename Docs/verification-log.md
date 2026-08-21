# Verification log

## 2026-08-08 — Phase 0 host inspection

Scope: Windows-host static inspection only.

Commands run before scaffold creation:

    Get-Command xcodebuild, xcrun, swift, swiftc
    git -c safe.directory=C:/room-scanner/room-scanner status --short
    Get-ChildItem -Force .\StarterFolder

Observed raw results:

    xcodebuild: absent
    xcrun: absent
    swift: absent
    swiftc: absent
    git status: ROOMSCANSTUDIO_MASTER_BUILD_PLAN.md was untracked
    StarterFolder: empty

Implication: no Xcode build, Swift package test, Simulator run, physical iPhone
or iPad run, LiDAR capture, CloudKit test, or export inspection can be claimed
from this machine. The Phase-0 verifier will check only static source/project
structure and will state this limitation in its result.

## Planned subsequent host checks

    python Scripts/verify_xcode_scaffold.py
    python -m json.tool <each fixture JSON>
    plistlib parse for Info.plist and PrivacyInfo.xcprivacy
    git -c safe.directory=C:/room-scanner/room-scanner status --short

The exact resulting outputs will be appended after the scaffold exists.

## 2026-08-08 — Scaffold structural oracle

Command:

    python Scripts/verify_xcode_scaffold.py

Raw result:

    static structure passed
    evidence limitation: static host checks only; no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.

This proves only that the verifier found the expected classic-group project
metadata, target/build phase membership, scheme references, plist/privacy
structure, fixture identifiers, portable core imports, and lack of active
team/profile/iCloud-entitlement configuration.

## 2026-08-08 — JSON/plist parsing and repository status

Command:

    Python standard-library json/plistlib parse over MockRoom-v1 JSON and app plists
    git -c safe.directory=C:/room-scanner/room-scanner status --short

Raw parse result:

    fixture JSON parsed: 6
    plist parsed: 2

Repository-status snapshot after scaffolding (before this log append) showed
only newly created, untracked scaffold files/directories plus the pre-existing
master plan. No files were staged, committed, built, or published.

## 2026-08-08 — Static negative control

The project text was altered in memory only (no file write) to append a
DEVELOPMENT_TEAM setting, then passed to the structural verifier's project
check. The probe returned:

    negative control detected forbidden signing setting: true

This demonstrates that the host checker can detect the signing configuration it
asserts is absent. It does not constitute Xcode signing or Apple-platform
validation.

## 2026-08-08 — Phase 1 local-library static checkpoint

Scope: host-static structure and fixture parsing after the Phase-1 local package
store, local SwiftData index, package wiring, library UI, and MockRoom review
contracts were authored.

Commands run:

    python Scripts/verify_xcode_scaffold.py

    $fixtureFiles = Get-ChildItem -LiteralPath 'RoomScanStudio\Fixtures\MockRoom-v1' -Recurse -File -Filter *.json
    foreach ($fixtureFile in $fixtureFiles) { Get-Content -LiteralPath $fixtureFile.FullName -Raw | ConvertFrom-Json | Out-Null }
    [xml] (Get-Content -LiteralPath 'RoomScanStudio\Resources\Info.plist' -Raw) | Out-Null
    [xml] (Get-Content -LiteralPath 'RoomScanStudio\Resources\PrivacyInfo.xcprivacy' -Raw) | Out-Null

Raw result:

    static structure passed
    evidence limitation: static host checks only; no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    fixture JSON parsed: 7 files
    plist XML parsed: 2 files

The verifier also executes memory-only negative controls that prove its package
wiring and duplicate-XCTest-declaration checks can fail. It verifies the seven
flat MockRoom-v1 JSON resources, app/test resource membership, the
repository-root local `RoomScanCore` product reference, `cloudKitDatabase:
.none`, no active signing/iCloud settings, and no Python cache artifacts.

The XCTest and XCUITest sources are authored but unexecuted. No `swift test`,
Xcode build, Simulator launch, app launch, device interaction, LiDAR capture,
CloudKit operation, or export inspection occurred on this host.

macOS proof still required:

    xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj -scheme RoomScanStudio
    xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -destination 'platform=iOS Simulator,name=iPhone 15' test
    swift test

Known unverified compile/API points are the precise current Xcode serialization
and resolver behavior for the local package reference, the SwiftData
`ModelConfiguration` overload with `cloudKitDatabase: .none`, and all
SwiftUI/XCTest selector behavior. Those require the macOS commands above.

## 2026-08-09 - Phase 1 local-only/index, lineage, and thumbnail repair

Scope: host-static checks after the local SwiftData policy seam, stored
revision-lineage validation, effective-freshness model, and bundled thumbnail
contracts were authored.

The generated fixture bitmap was copied once with `Copy-Item` from the
operator-supplied generated-image path into
`RoomScanStudio/Fixtures/MockRoom-v1/assets/thumbnail.png`. The source was not
modified or deleted. Copy-time evidence was:

    fixture thumbnail copied: 2494646 bytes; SHA256 matched

Commands run:

    python Scripts/verify_xcode_scaffold.py

    python -c "import json, pathlib, plistlib; fixture = pathlib.Path('RoomScanStudio/Fixtures/MockRoom-v1'); json_files = sorted(fixture.rglob('*.json')); [json.loads(path.read_text(encoding='utf-8')) for path in json_files]; plist_files = [pathlib.Path('RoomScanStudio/Resources/Info.plist'), pathlib.Path('RoomScanStudio/Resources/PrivacyInfo.xcprivacy')]; [plistlib.loads(path.read_bytes()) for path in plist_files]; print(f'fixture JSON parsed: {len(json_files)} files'); print(f'plist parsed: {len(plist_files)} files')"

    PowerShell recursive check for __pycache__, *.pyc, and *.pyo

Raw result:

    static structure passed
    evidence limitation: static host checks only; no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    fixture JSON parsed: 7 files
    plist parsed: 2 files
    python cache scan: none

The verifier now checks the explicit local-only SwiftData source policy
(`groupContainer: .none` and `cloudKitDatabase: .none`), stored-lineage and
effective-freshness source contracts, thumbnail PNG signature and fixture/PBX
membership, narrow thumbnail-read/render contracts, and their author-time
test names. Its pass is not Swift/Xcode execution evidence.

New XCTest contracts cover stored on-disk later-initial/missing/self/future
revert rejection, valid duplicate roots, effective freshness after append and
restore without immutable revision changes, thumbnail byte round trip, fixture
thumbnail resource decoding, controller publication, explicit mock Save, and
Discard. They are authored but unexecuted: this Windows host has no Swift,
Xcode, Apple SDK, or Simulator.

macOS proof still required:

    xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj -scheme RoomScanStudio
    xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -destination 'platform=iOS Simulator,name=iPhone 15' test
    swift test

The most important remaining API uncertainty is the selected Xcode SDK's
acceptance of the `ModelConfiguration` initializer with both
`groupContainer: .none` and `cloudKitDatabase: .none`; SwiftData, UIKit image
decoding, SwiftUI thumbnail rendering, and XCTest behavior remain unverified
until those macOS commands run.

## 2026-08-09 - Phase 2A Core/evidence static checkpoint

Scope: Foundation-only RoomScanCore spatial/provenance values, immutable
revision evidence plans, capture reducer, and atomic initial-capture staging.
No RoomPlan, ARKit, UIKit, SwiftUI, SwiftData, CloudKit, capture UI, or PBX
adapter was added in this slice.

The focused XCTest contracts were authored before their production contracts.
On this host they could not be run. The first Phase-2A structural oracle run,
before the new source files/contracts existed, returned:

    static structure failed
    - missing required file: RoomScanCore\Sources\RoomScanCore\RoomCaptureReducer.swift
    - Phase-2A core contract is missing: spatial point
    - Phase-2A core contract is missing: four-by-four transform
    - Phase-2A core contract is missing: classification confidence
    - Phase-2A core contract is missing: element provenance
    - Phase-2A core contract is missing: mobility assessment
    - Phase-2A core contract is missing: revision evidence plan
    - Phase-2A core contract is missing: revision evidence attachment
    - Phase-2A core contract is missing: atomic initial capture commit
    - Phase-2A core contract is missing: revision evidence file validation
    - Phase-2A core contract is missing: evidence-aware duplicate
    - Phase-2A core contract is missing: capture phase reducer
    - Phase-2A core contract is missing: attempt-token capture state
    - Phase-2A core contract is missing: discard cleanup effect

Commands run after the contracts were authored:

    python Scripts/verify_xcode_scaffold.py

    python -c "... phase2_core_contract_errors(models.replace('sha256Hex', 'missingDigest'), store, reducer, sha) ..."

    python -c "... json/plistlib parse seven fixture JSON files and two plists; assert PNG signature ..."

    PowerShell recursive check for __pycache__, *.pyc, and *.pyo

    rg source absolute-path/secret scan over RoomScanCore, RoomScanStudio,
    RoomScanStudio.xcodeproj, Scripts, and Package.swift

    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw results:

    static structure passed
    evidence limitation: static host checks only; no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    negative control detected removed evidence contract: true
    negative control detected removed live evidence digest guard: true
    negative control detected removed evidence-directory closure call: true
    fixture JSON parsed: 7 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    source absolute-path/secret scan: none

The host verifier now checks the Foundation-only Core source boundary, spatial
and mobility contracts, canonical `objectElements` migration with legacy
`movableElements` decoding, capture/coordinate provenance, immutable evidence
digest/directory closure, scanning-only single-flight reference-photo behavior,
capture teardown/cancellation effects, and author-time test contract names.
The in-memory negative controls prove that this verifier path would report a
missing digest declaration, a removed live digest comparison, or a removed
evidence-directory closure call.

Apple documentation identifies `CapturedRoomData.encode(to:)` and
`CapturedRoomData.init(from:)` as the intended persistence APIs, and documents
the RoomPlan instruction/capture-error and ARKit tracking categories mirrored
by the Core values. No Apple API was invoked here. The raw-mesh/world-map
branches remain optional physical-device gates, and all Swift/XCTest/Xcode,
Simulator, LiDAR iPhone/iPad, CloudKit, and export evidence remains open.

The repository is still a fresh, entirely untracked scaffold; status listed
the pre-existing `ROOMSCANSTUDIO_MASTER_BUILD_PLAN.md` and all authored project
files. Nothing was staged, committed, published, built, or executed on Apple
hardware.

## 2026-08-09 - Phase 2A legacy-evidence, origin, and casing repair

Scope: Foundation-only RoomScanCore repair only. No PBX, app UI, RoomPlan,
ARKit, SwiftData, CloudKit, capture adapter, or export implementation changed.

Focused XCTest contracts were authored before the corresponding Core guards.
They cover public Save/append rejection of plan-less `evidence/` assets,
case-aliased `Evidence/` rejection on public write and load, legacy canonical
plan-less evidence load/restore/duplicate byte preservation, RoomPlan element
origin/provenance requirements, hard-coded SHA-256 boundary vectors and stream
chunk sizes, and same-token capture termination ignored after review. They were
not executable on this host because Swift/Xcode is absent.

Commands run:

    python Scripts/verify_xcode_scaffold.py

    Python in-memory mutation removing
    validateCanonicalEvidenceNamespace(revisionURL:revisionURL, root:root)
    before calling phase2_core_contract_errors

    Python standard-library parse of seven fixture JSON files, two plists, and
    the PNG signature

    PowerShell recursive check for __pycache__, *.pyc, and *.pyo

    rg source absolute-path/secret scan over RoomScanCore, RoomScanStudio,
    RoomScanStudio.xcodeproj, Scripts, and Package.swift

Raw results:

    static structure passed
    evidence limitation: static host checks only; no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    negative control detected removed case-aliased evidence guard: True
    fixture JSON parsed: 7 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    source absolute-path/secret scan: none

The direct in-memory verifier import initially generated only
`Scripts/__pycache__/verify_xcode_scaffold.cpython-313.pyc`; its resolved path
was confirmed under the workspace `Scripts` directory and that exact generated
cache directory was removed with PowerShell before the final cache scan.

New writes reserve the lowercase `evidence/` namespace for declared,
digest-checked plans. Pre-Phase-2 packages may retain an existing canonical
plan-less evidence tree only through internal load/duplicate/restore migration
handling after regular-file and symlink checks; those legacy files have no
byte-count or SHA-256 integrity guarantee until a later migration. This is a
backward-compatibility boundary, not an assertion that legacy evidence is
verified.

No Swift build/test, Xcode resolution, Simulator, app launch, Apple API call,
or physical-device evidence occurred. The remaining risks are compile/runtime
verification of the authored Swift tests and APIs on a macOS/Xcode SDK, plus
actual filesystem casing behavior on Apple volumes. The static source checks
cannot prove either behavior.

## 2026-08-09 - Phase 2A v1/v2 evidence compatibility boundary

Scope: Foundation-only RoomScanCore compatibility repair only. No PBX, app UI,
RoomPlan, ARKit, SwiftData, CloudKit, capture adapter, or export implementation
changed.

Newly created package manifests now explicitly use and validate v2. A missing
revision `evidenceCompatibility` field is accepted only when the containing
manifest is the historical v1 format. New public initial and append writes
record `.strict`; a plan-less `evidence/` tree is therefore rejected in a new
v2 revision and in a strict appended revision of an otherwise historical v1
project. Internal duplicate/restore can retain an explicit
`.legacyV1Planless` mode only after its source package has already loaded and
validated as historical v1. That legacy evidence has no digest guarantee until
a later migration.

Focused XCTest contracts were authored before the corresponding Core changes.
They cover a new v2 plan-less evidence injection, a strict append to a v1
package followed by the same injection, and valid v1 load/restore/duplicate
byte preservation. They were not executable on this host because Swift/Xcode
is absent.

Commands run:

    python Scripts/verify_xcode_scaffold.py

    Python in-memory mutation replacing the historical-v1 compatibility gate
    before calling phase2_core_contract_errors

    Python standard-library parse of seven fixture JSON files, two plists, and
    the PNG signature

    PowerShell recursive check for __pycache__, *.pyc, and *.pyo

    rg source absolute-path/secret scan over RoomScanCore, RoomScanStudio,
    RoomScanStudio.xcodeproj, Scripts, and Package.swift

Raw results:

    static structure passed
    evidence limitation: static host checks only; no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    negative control detected removed historical-v1 compatibility gate: True
    fixture JSON parsed: 7 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    source absolute-path/secret scan: none

The in-memory negative control demonstrates that the static oracle reports a
missing historical-v1 gate. It does not execute Swift storage behavior. No
Swift build/test, Xcode resolution, Simulator, app launch, Apple API call, or
physical-device evidence occurred; those remain macOS/Xcode and physical-device
gates.

## 2026-08-09 - Phase 2B deterministic capture subpass 1

Scope: app-level capability split, deterministic capture dependencies/driver,
attempt-local scratch, reducer coordinator, black semantic Canvas, source/PBX
wiring, and authored app/UI-test contracts. No live RoomPlan/ARKit adapter,
camera session, AR session, rescan, viewer, export, or CloudKit implementation
was added.

The capture gate now depends only on `RoomCaptureSession.isSupported`. Scene
mesh is shown as an optional raw-evidence capability: it does not suppress a
RoomPlan-capable capture path. `--use-simulated-capture` injects a deterministic
fixture-evidence driver that writes only attempt-local scratch outside the
authoritative project root. It follows explicit Prepare, Start, optional
reference photo, Stop, Review, Save, and Discard transitions through the Core
reducer. Save invokes `commitInitialCapture` only after review; Discard emits
cleanup and creates no profile. The normal app dependency branch intentionally
uses an unavailable-driver placeholder until a later Apple-adapter subpass.

Commands run:

    python Scripts/verify_xcode_scaffold.py

    Python -B standard-library parse of seven fixture JSON files, two plists,
    and the PNG signature; in-memory mutation removing the RoomPlan-only
    capture-availability return before calling the verifier contract helper

    PowerShell recursive check for __pycache__, *.pyc, and *.pyo

    rg source absolute-path/credential scan over RoomScanCore, RoomScanStudio,
    RoomScanStudio.xcodeproj, Scripts, and Package.swift

    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw results:

    static structure passed
    evidence limitation: static host checks only; Phase-2B coverage is deterministic simulated-capture wiring, not an Apple RoomPlan/ARKit adapter. No Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    fixture JSON parsed: 7 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    negative control detected removed RoomPlan-only capture gate: true
    python cache scan: none
    source absolute-path/credential scan: none

The static oracle checks the new classic-PBX source membership, capability
contract, simulator switch, explicit store-commit wrapper, core capture
accessibility identifiers, deterministic evidence omissions, and an absence of
ARKit, RoomPlan, AVCaptureSession, and AR-session configuration/delegate calls
in the new deterministic capture sources. Its in-memory negative control proves
that removing the RoomPlan-only availability return is reported. This is source
wiring evidence only; it does not execute Swift or iOS behavior.

The XCTest and XCUITest additions are authored but unexecuted. This Windows
host has no Swift toolchain, Xcode, Apple SDK, Simulator, or physical LiDAR
hardware. Required later proof remains Xcode package resolution/build/tests,
Simulator execution of the deterministic route, and physical iPhone/iPad
verification of the real app-owned RoomPlan/ARKit adapter that is intentionally
not implemented in this subpass.

## 2026-08-09 - Phase 2B deterministic capture hardening

Scope: deterministic coordinator, scratch-workspace, lease, UI-test, PBX, and
host-oracle hardening only. No RoomPlan/ARKit adapter, camera session, AR
session, rescan, viewer, export, CloudKit, or live-device assertion was added.

The coordinator now treats the processed prepared review as the semantic truth:
the display changes to that snapshot as processing completes and later live
same-token snapshots are ignored outside starting/scanning/stopping/processing.
Discard cancels and awaits tracked scratch-writing start/photo/processing work
plus a driver writer barrier before cleanup. Cleanup failure stays in the
nonterminal cleanup state, exposes `capture.cleanupError`, and has an explicit
retry path. The deterministic environment recovers only owned scratch orphans,
rejects symbolic scratch roots/attempt leaves, uses a one-coordinator lease in
the V1 single-scene application, blocks back/interactive dismissal after an
attempt begins, and blocks Save while optional GPS is in flight.

Focused XCTest contracts were added for review snapshot freezing and persisted
semantic fidelity, cancellation-before-cleanup with a suspended writer,
cleanup retry, delayed GPS save/discard races, coordinator-lease construction
count, and scratch link/orphan behavior. XCUITest contracts cover Close/Discard
during scanning and processing, simulated photo failure, GPS denial with
manual-location Save, save failure then Discard, and fail-once/persistent
processing failures. These tests are authored only; they were not run.

Commands run:

    python -B Scripts/verify_xcode_scaffold.py

    Python -B standard-library parse of seven fixture JSON files, two plists,
    and the fixture PNG signature

    Python -B in-memory mutations removing the live-snapshot phase gate and
    scratch-writer barrier before calling phase2b_deterministic_capture_contract_errors

    PowerShell recursive check for __pycache__, *.pyc, and *.pyo

    Python -B source absolute-path/credential scan over RoomScanCore,
    RoomScanStudio, RoomScanStudio.xcodeproj, Scripts, and Package.swift

    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw results:

    static structure passed
    evidence limitation: static host checks only; Phase-2B coverage is deterministic simulated-capture wiring, not an Apple RoomPlan/ARKit adapter. No Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    fixture JSON parsed: 7 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    negative control detected weakened live-snapshot phase gate: true
    negative control detected removed scratch-writer barrier: true
    python cache scan: none
    source absolute-path/credential scan: none

The fresh scaffold remains entirely untracked, including the pre-existing
master plan. Nothing was staged, committed, built, or executed on Apple
hardware. Remaining proof is a macOS/Xcode build, authored XCTest/XCUITest
execution on Simulator, and physical iPhone/iPad validation of the future real
RoomPlan adapter and scratch filesystem behavior on Apple volumes.

## 2026-08-09 - Phase 2B production RoomPlan adapter static checkpoint

Scope: compile-intended iOS 17 production camera/location providers and an
Apple RoomPlan adapter, plus the Foundation-only semantic mapper, PBX/test
membership, source oracle, and documentation. No rescan, raw mesh collection,
world-map persistence, viewer, CloudKit, or alternate-export work was added.

Focused XCTest contracts were authored before their production source: the
portable `RoomPlanSemanticMapperTests` cover surface/object separation,
attempt-local stable app IDs, provenance, conservative mobility, zero
out-of-plane surfaces, and invalid geometry. `AppleCaptureDependencyTests`
cover pure permission mapping and production-factory declarations without
opening a camera. These tests are authored but unexecuted because this host has
no Swift toolchain or Apple SDK.

The first integration verifier run was intentionally red after production
injection replaced the deterministic unavailable-driver placeholder:

    static structure failed
    - Phase-2B deterministic contract is missing: production placeholder

The source oracle was then updated to require the production adapter rather
than the obsolete placeholder. It requires a single injected `ARSession`,
RoomCaptureSession-only delegation, final `stop(pauseARSession: true)`, raw and
processed JSON plus USDZ evidence paths and hashes, same-session reference
photo API, documented identifier/category mapping, PBX membership, and bans on
AVCaptureSession, RoomCaptureView, ARSession.run/delegate, raw descriptive
identifier persistence, and photo fallbacks. Its in-memory negative controls
remove ARSession injection/high-resolution capture or add ARSession.run and
must produce contract errors.

Commands run after the source and oracle changes:

    python -B Scripts/verify_xcode_scaffold.py

    PowerShell standard-library parsing of seven fixture JSON files, two plist
    files, and the fixture PNG signature

    PowerShell scans for __pycache__, *.pyc, *.pyo, absolute workspace paths,
    credential-like strings, and forbidden camera/AR-session API paths

    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

The final host-only oracle result was:

    static structure passed
    evidence limitation: static host checks only; Phase-2B source wiring includes a compile-intended Apple RoomPlan/ARKit adapter and deterministic simulated capture, but no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.
    fixture JSON parsed: 7 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    source absolute-path/credential scan: none
    forbidden production capture API scan: none

The production source uses one ARSession per driver and injects it into
RoomCaptureSession. It never calls ARSession.run, assigns an ARSession delegate,
or starts a separate camera session. Camera permission occurs only after
Prepare, location only after explicit request, and reference photos use the
same session while scanning. Stop ends the V1 session with
`pauseARSession: true`; future rescan work therefore cannot assume coordinate
continuity. Raw mesh/world-map/provenance artifacts are explicit omissions,
not fabricated outputs.

Open gates: an installed macOS/Xcode iOS 17 SDK must compile the exact
RoomCaptureSession delegate signatures, `CapturedRoom` identifiers/categories,
RoomBuilder/export calls, and the isolated `try await
arSession.captureHighResolutionFrame()` spelling. Simulator must execute the
deterministic route. LiDAR iPhone and iPad must prove capability, permissions,
custom black canvas behavior, save/discard, native evidence bytes, same-session
photo behavior, and the optional mesh gate. No Apple API, simulator, XCTest,
XCUITest, or device behavior has run from this Windows host.

## 2026-08-09 - Phase 2B capture hardening static checkpoint

Scope: harden the existing deterministic and compile-intended Apple capture
paths without adding rescan, raw-mesh collection, world-map persistence,
CloudKit, or exports. The written XCTest contracts were extended before the
source changes. They cover the didUpdate-only RoomPlan full-snapshot policy,
the pure final-end ownership gate, semantic-plus-operational guidance recovery,
GPS cancellation before terminal routing, actionable termination copy, and an
authorized-GPS/reference-photo deterministic Save that reloads metadata, the
photo document, and copied photo bytes. They are authored but unexecuted: this
Windows host has no Swift toolchain, Xcode, Simulator, or Apple SDK.

The production adapter now treats `didAdd`, `didRemove`, and `didChange` as
partial RoomPlan deltas and never uses them to replace the normalized Canvas
snapshot. Only `didUpdate` enters that handler. It retains AR/RoomPlan session
ownership after `stop(pauseARSession: true)` until the matching asynchronous
`didEndWith` callback is observed. Cleanup uses a bounded polling wait with no
checked continuation; a timeout leaves the workspace and cleanup UI retryable.
The per-request location provider cancels and resumes only the matching
continuation, stops location updates defensively, and uses a fresh manager/
proxy identity so stale callbacks cannot attach to the next attempt. When mesh
support is present, the UI still states that V1 does not collect raw mesh.

While strengthening the oracle, one run correctly failed because its older
generic text check could not distinguish the live snapshot gate from the new
operational-observation gate:

    static structure failed
    - verifier self-test did not detect a weakened live-snapshot phase gate

The verifier was then narrowed to inspect the `acceptsLiveSnapshot` function
body itself. Its in-memory negative controls now detect a removed app-owned
ARSession injection, forbidden ARSession.run, a partial-delta full-snapshot
call, a removed final-end observation, a removed attempt-scoped GPS cancel,
and a removed same-session high-resolution photo call. This proves only the
static source oracle's sensitivity, not Apple runtime behavior.

Commands run after the repair:

    python -B Scripts/verify_xcode_scaffold.py
    PowerShell standard-library JSON/plist/PNG parsing and cache/path/credential scans
    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Final host result:

    static structure passed
    evidence limitation: static host checks only; Phase-2B source wiring includes a compile-intended Apple RoomPlan/ARKit adapter and deterministic simulated capture, but no Xcode build, Swift tests, Simulator, device, LiDAR, CloudKit, or export inspection was performed.

Still open: macOS/Xcode must compile the exact RoomPlan delegate and
high-resolution-frame API surface, then Simulator must run the deterministic
contracts and physical LiDAR iPhone/iPad devices must validate the custom
canvas, final-end cleanup timing, real permission/location behavior, optional
mesh messaging, evidence bytes, and reference-photo orientation.

## 2026-08-09 - Phase 3 V1-A fixture-only rescan and capture-cancellation repair

Scope: Foundation-only fixture rescan proposal/acceptance, app fixture provider
and review flow, sidecar resource/PBX wiring, host oracle, and four bounded
capture hardening repairs. No live rescan registration, ARWorldMap persistence,
additional camera/AR session, raw-mesh collection, viewer, CloudKit, or export
format work was added.

The governing safety clause is: “A rescan candidate is valid only if one of
these registrations is proven: 1. continuous capture in the original app-owned
ARSession, or 2. successful relocalization against a recorded ARWorldMap.” V1
production does not meet either condition: final capture uses
`stop(pauseARSession: true)` and no world map is recorded. Its provider is
therefore hard-unavailable and creates no camera/AR work. Only the explicit
`--use-deterministic-rescan-fixture` test route loads the stable sidecar.

Focused XCTest contracts were authored for the Core proposal engine before its
production source: exact base/candidate bijection, deterministic digest under
base/match/candidate order changes, source/provenance/geometry validation
(including finite usable affine candidate transforms with a non-singular basis), tamper,
stale/double acceptance, immutable parent bytes, photo copying, and
initial→rescan→revert lineage. App/XCUITest contracts cover production
unavailability and fixture preview, Undo, Accept, and Revert. They are authored
but unexecuted because this Windows host has no Swift toolchain, Xcode,
Simulator, or Apple SDK.

The accepted fixture path reloads the package and recomputes the proposal under
the existing same-process root lock. It preserves app-owned base element IDs,
uses candidate geometry/provenance only, preserves annotations/measurements/
photos, labels measurements unchanged and unrevalidated, and appends exactly
one immutable `.rescan` child with a deterministic-fixture evidence plan that
contains six explicit unavailable artifacts and no evidence directory. Generic
public `.rescan` append is rejected. Undo calls no store API and allocates no
revision ID. Candidate additions/deletions, wrong fixture/frame/proof,
layer/kind mismatch, duplicate mappings, nonfinite/invalid candidate geometry,
and tampering fail closed. This is not mesh fusion or a live registration claim.

The bounded capture repairs add an explicit reducer GPS-cancel effect on live
termination, cancellation/attempt/phase guards before queued camera, start,
GPS, processing, and photo dependency calls, a synchronous queued-effect fence
before cleanup, stale one-shot Core Location completion as nonfatal no-fix, and
a fake final-end cleanup-retry contract. A delayed GPS test resolves a late
location after termination and asserts it cannot attach or create a package.

Commands run after the source, PBX, verifier, and documentation changes:

    python -B Scripts/verify_xcode_scaffold.py
    python -B -c "standard-library JSON/plist/PNG parse"
    PowerShell cache, mojibake, absolute-path/credential, and forbidden-rescan scans
    git -c safe.directory=C:/room-scanner/room-scanner diff --check
    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw host results:

    static structure passed
    evidence limitation: static host checks only; Phase-3 V1-A verifies fixture-only rescan source/PBX wiring and the compile-intended Apple capture path, but no Xcode build, Swift tests, Simulator, device, LiDAR registration, ARWorldMap relocalization, CloudKit, or export inspection was performed.
    fixture JSON parsed: 8 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    mojibake scan: none
    source absolute-path/credential scan: none
    rescan forbidden-implementation scan: none
    diff --check: no output / success

The successful verifier run also executed in-memory negative controls for
broken local-package wiring, duplicate XCTest classes, Phase-2 evidence and
capture barriers, removed queued-effect cancellation, removed unproven
registration rejection, and a weakened production rescan gate. Each would make
the validator fail if its source contract were removed. This establishes only
the static oracle's sensitivity.

Still open: macOS/Xcode must compile all new Swift sources and exact RoomPlan/
ARKit APIs, Simulator must execute the authored deterministic XCUITest flows,
and physical LiDAR iPhone/iPad tests must prove real capture, session-final-end
timing, reference photos, optional mesh behavior, and a production continuous-
session or ARWorldMap-relocalization registration before any live master rescan
is enabled.

## 2026-08-09 - Phase 4 saved-room viewer and immutable editor checkpoint

Scope: saved normalized-room viewing and copy-on-write semantic editing only.
No capture, live AR viewer, mesh fusion, native USDZ rendering, CloudKit, or
export behavior was added. Focused XCTest/XCUITest contracts were authored
before the implementation work, but were not executed: this Windows host has
no Swift toolchain, Xcode, Apple SDK, Simulator, or device.

The Core contracts cover backward-compatible spatial annotation/measurement
documents, finite and anchored spatial validation, camera presets/clamps and
incremental orbit inputs, first-person no-clip movement, copy-on-write element/
manual-object/annotation/measurement/photo edits, non-yaw transform-basis
preservation, expected-head rejection, fault/retry, parent-byte immutability,
and photo/evidence/future-attachment carry-forward. App contracts cover the
pure scene plan and a controller-backed optimistic edit. UI contracts cover
viewer controls, explicit no-clip disclosure, a Save that persists a typed
label without a separate Apply tap, Cancel, and invalid pending form input that
must not create a revision.

The iOS viewer source is deliberately `ARView` `.nonAR` with automatic session
configuration disabled, an explicit `PerspectiveCamera`, cached scene-plan
rebuilds, and separate visibility roots. It has no AR-session run/configuration
or camera-request path. RealityKit API compilation/rendering is still a named
macOS/Xcode gate. The editor only sends an in-memory payload to the locked
store-owned optimistic commit; Save advances the head with a new immutable
`.edit`, while the prior revision remains unchanged.

MockRoom-v1 was enriched without changing its stable project/revision/element
IDs or seven-document layout: it now has transforms/polygons, an anchored note,
paired measurement endpoints, and a photo pose marker. The deterministic
bundle PNG is deliberately staged both as the thumbnail and as the revision
photo asset on explicit Save; it is not a live camera artifact.

Commands run after Phase 4 source, PBX, verifier, fixture, and documentation
updates:

    python -B Scripts/verify_xcode_scaffold.py
    python -B - < standard-library fixture JSON/plist/PNG probe
    PowerShell cache, mojibake, absolute-path/credential, and viewer AR/camera scans
    git -c safe.directory=C:/room-scanner/room-scanner diff --check
    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw host results:

    static structure passed
    evidence limitation: static host checks only; Phase-4 verifies fixture-backed viewer/editor source/PBX wiring, non-AR source guards, and compile-intended Apple capture/rescan paths, but no Xcode build, Swift tests, Simulator, RealityKit render, device, LiDAR registration, ARWorldMap relocalization, CloudKit, or export inspection was performed.
    fixture JSON parsed: 8 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    mojibake scan: none
    source absolute-path/credential scan: none
    viewer forbidden AR/camera scan: none
    diff --check: no output / success

The host verifier's in-memory negative controls now also remove the optimistic
edit expected-head guard, parent-asset carry-forward call, or `.nonAR` camera
mode; each mutation is required to produce a static contract error. This proves
the narrow source oracle is sensitive to those omissions, not that Apple APIs
compile or run.

Open gates: a macOS iOS-17-or-later Xcode build must compile the exact
RealityKit `ARView`, `PerspectiveCamera`, entity-child cleanup, mesh-box, and
transform APIs. Simulator must execute all authored viewer/editor tests. A
physical iPhone and iPad run must assess non-AR rendering, Dynamic Type/layout,
gesture behavior, and package edit recovery. No Apple-platform claim is made
from this checkpoint.

## 2026-08-09 - Phase 5 head-revision export checkpoint

Scope: bounded head-revision materialization, deterministic ZIP32 STORE,
manifest/source-map closure, UIKit-derived/share wiring, marker-proven export
lease recovery, PBX/test wiring, and host-static verification. This is not a
backup or full-history archive. No Phase 6/cloud behavior was added.

The store-owned export path reloads and validates the expected head under the
same-process package lock, streams a deep copy into an external owned workspace,
and releases the lock before derived work. It excludes the project manifest,
prior revisions, pending/ownership records, package exports, and unreferenced
files. Exported metadata, revision, and photos JSON use rewritten app-owned
paths; `source-map.json` records project-root versus revision-root references.
The tests include a scope-collision control so equal relative names cannot map
across authority roots.

The final ZIP permits at most 4096 entries. Materialization reserves the two
required derived entries and `manifest.json`, so it permits at most 4093 source
entries. Focused Core contracts cover that arithmetic, the injected ZIP boundary,
bounded CRC/SHA streaming, post-preflight mutation, source-package immutability,
attachments, unavailable/not-requested evidence, and a complete unique
`requestedOutputs` closure. App contracts cover retained share leases, combined
export/cleanup failure retry, source-reference decode, and marker-valid direct
orphan recovery while preserving unmarked lookalikes and links. These XCTest and
XCUITest sources are authored but were not executed because this host has no
Swift toolchain, Xcode, Apple SDK, Simulator, or device.

Commands run:

    python -B Scripts\verify_xcode_scaffold.py
    python -B - < standard-library fixture JSON/plist/PNG probe
    PowerShell recursive __pycache__/pyc/pyo scan
    rg source absolute-path/credential scan
    rg stale Phase-5 ZIP/defer wording scan
    python -B - < mojibake codepoint scan
    git -c safe.directory=C:/room-scanner/room-scanner diff --check
    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw host results:

    static structure passed
    evidence limitation: static host checks only; Phase-5 verifies fixture-backed head-export source/PBX wiring, deterministic ZIP/source-reference/lease contracts, and compile-intended UIKit/Apple capture/rescan paths, but no Xcode build, Swift tests, Simulator, RealityKit render, device, LiDAR registration, ARWorldMap relocalization, CloudKit, ZIP consumer inspection, PNG/PDF rendering, native USDZ export, or system share handoff was performed.
    fixture JSON parsed: 8 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    source absolute-path/credential scan: none
    stale Phase-5 export wording scan: none
    mojibake codepoint scan: none
    diff --check: no output / success

The verifier also executes in-memory negative controls that remove the export
expected-head guard, outbound JSON rewrite, marker-proven cleanup, ZIP second-
pass equality, no-overwrite partial creation, final ZIP entry cap,
requested-output closure, or UIKit share-bridge boundary. Each must make the
static contract checker fail. This establishes static-oracle sensitivity only.

Still open: macOS/Xcode must compile and run the portable/app/UI test suites;
independent ZIP readers, Apple Files/Archive Utility, and Windows Explorer must
inspect a produced archive; UIKit must render the PNG/PDF and complete/cancel a
share sheet; and physical iPhone/iPad tests must inspect native USDZ when
present and marker-lease recovery. No archive was produced or independently
inspected on this Windows host.

## 2026-08-09 - Phase 6 optional private backup/recovery checkpoint

Scope: Foundation-only full-project snapshot/archive/recovery contracts;
explicit local CloudKit consent, isolated private-zone/CKAsset transport,
marker-owned backup scratch, app/UI/PBX/test wiring, and host-static checks.
This is conservative manual backup and recovery, not synchronization. Local
SwiftData remains explicitly `groupContainer: .none` and
`cloudKitDatabase: .none`.

The Core archive path covers the package manifest, metadata, all immutable
revisions, required v2 revision ownership records, and validated owned assets
while excluding links, special files, exports, pending, staging, and scratch
artifacts. Its canonical manifest is byte-bound to a deterministic snapshot ID.
Recovery performs bounded strict ZIP checks before isolated package validation;
an absent project restores exactly, an identical snapshot is a no-op, and a
divergent project requires explicit Recover as Copy. The copy rewrites all
project-ID-bearing documents while retaining revision IDs, lineage, and asset
bytes.

Cloud use is disabled by default. Enabling the preference does not contact
CloudKit; Check, List, Back up, and Recover are explicit operations. The only
CloudKit source uses an exact operator-supplied container identifier, private
zone `RoomScanStudioBackupsV1`, record type `RSSProjectBackupV1`, one
content-addressed `CKAsset`, individual bulk-operation Results, and
`.ifServerRecordUnchanged`. There is no committed entitlement, development
team, profile, guessed container, or `CKContainer.default()` fallback. Listing
retains no more than 200 valid records and counts/skips no more than 200
malformed successful descriptors, stopping paging at either cap and disclosing
that additional records were not loaded.

Authored XCTest/XCUITest contracts include archive determinism/full-history
closure, CRC/digest/manifest/ZIP-closure/canonical-byte failures, v1 ownership
compatibility, exact/no-op/copy recovery, explicit consent and retries,
bounded listing, cleanup retry, and explicit fake UI backup/recovery actions.
They were not executed on this host.

Commands run:

    python -B Scripts\verify_xcode_scaffold.py
    python -B -c <standard-library fixture JSON/plist/PNG probe>
    PowerShell recursive __pycache__/pyc/pyo scan
    python -B - <mojibake, source absolute-path, and credential scans>
    rg CloudKit/signing forbidden-source scan
    git -c safe.directory=C:/room-scanner/room-scanner diff --check
    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw host results:

    static structure passed
    evidence limitation: static host checks only; Phase-6 verifies fixture-backed prior-phase wiring plus Core full-project backup/recovery, strict ZIP/manifest/ownership boundaries, explicit local CloudKit consent/configuration, marker-owned scratch, and compile-intended private-zone/CKAsset source paths, but no Xcode build, Swift tests, Simulator, RealityKit render, device, LiDAR registration, ARWorldMap relocalization, CloudKit development-container call, entitlement/profile, CKAsset upload/download, ZIP consumer inspection, PNG/PDF rendering, native USDZ export, or system share handoff was performed.
    fixture JSON parsed: 8 files
    plist parsed: 2 files
    fixture PNG signature parsed: true
    python cache scan: none
    mojibake scan: none
    source absolute-path scan: none
    credential scan: none
    cloud/signing forbidden-source scan: none
    diff --check: no output / success

Open gates: macOS/Xcode must compile the isolated CloudKit API spellings and
execute the authored Swift/XCTest/XCUITest suites. A signed development
container must prove account state, missing-zone read behavior, explicit upload
and idempotency, retry/cancellation lookup, CKAsset size acceptance and bounded
download copy, exact/copy recovery, and cleanup retry. The local 512 MiB bound
does not assert Apple accepts a CKAsset of that size. No CloudKit call,
entitlement/profile, device, Simulator, ZIP consumer, or share-sheet behavior
was exercised on this Windows host.

### Phase-6 availability follow-up: bounded malformed backup records

The CloudKit list adapter now isolates a successful record only when its
descriptor fails local validation: valid descriptors remain listable, while a
bounded skipped-malformed count is published and visibly disclosed. A per-record
CloudKit `Result.failure` still maps to a failed explicit List action. Pagination
stops as soon as either the 200 valid-record or 200 malformed-record
representation is full, so it does not fetch a further page merely to discard
it. The canonical full-backup archive mapping is also now enforced as sequential
app-owned `package/files/file-####.<safe-ext>` names at both build and recovery;
the signed package-relative mapping remains the restoration authority.

Additional authored, unrun contracts cover valid-plus-malformed publication,
bounded paging, failure preservation, and build/recovery rejection of a forged
noncanonical archive path. `python -B Scripts\verify_xcode_scaffold.py` passed
after these source/verifier mutations. This remains host-static evidence only;
no CloudKit call or Swift/Xcode test execution occurred.

## 2026-08-09 - Phase 7 release/accessibility/CI checkpoint

Scope: release build substitutions, a mechanically resized opaque RGB AppIcon,
required-reason privacy manifest entries, semantic adaptive palette/action-row
source contracts, authored Dynamic Type UI test coverage, a pure dynamic
simulator selector, pinned macOS CI workflow, and release operating documents.

Commands run for this checkpoint:

    python -B Scripts\select_simulators.py --self-test
    python -B Scripts\verify_xcode_scaffold.py
    python -B -c <JSON/plist/PNG IHDR probe>
    PowerShell cache/mojibake/absolute-path/credential scans
    git -c safe.directory=C:/room-scanner/room-scanner diff --check
    git -c safe.directory=C:/room-scanner/room-scanner status --short --untracked-files=all

Raw host results:

    simulator selector self-test passed
    Phase-7 mutation controls detected: contrast, workflow pin, dark context, PNG truncation
    Privacy Policy HTTPS-guard mutation detected
    Privacy Policy build-setting channel parsed: blank default in Debug and Release
    static structure passed
    fixture JSON parsed: 8 files
    plist parsed: 2 files
    AppIcon PNG IHDR parsed: 1024x1024, 8-bit RGB, opaque
    python cache scan: none
    mojibake scan: none (master-plan file excluded)
    source absolute-path scan: none
    credential scan: none
    diff --check: no output / success
    git status: fresh scaffold files are untracked; no staging/commit occurred

The static verifier also executes in-memory negative controls for a reduced
contrast literal, an unpinned checkout action, fixed-dark palette misuse, and
truncated/corrupt icon PNG chunks. That proves oracle sensitivity only.

The parsed privacy manifest reflects the current unsigned-off empty
collected-data configuration only. Distribution remains blocked until the
Account Holder records either its private-only rationale or the applicable
four-category disclosure and Linked determinations.

The same release block now applies to the operator-owned
`ROOMSCANSTUDIO_PRIVACY_POLICY_URL`: the host contract accepts only a strict
absolute HTTPS value at runtime, and a blank or unresolved build setting is
shown as **Privacy Policy not configured for this build** rather than a
fabricated link. No owner-approved URL exists in this repository.

Authored, unrun app/UI contracts cover resolver rejection of blank, unresolved,
HTTP, credential-bearing, fragmented, and malformed values; valid HTTPS
acceptance; and the Home settings absence state. Swift/XCTest/XCUITest has not
run on this host.

At this checkpoint the Phase 7 CI workflow was authored but had not run. No
Swift/Xcode/Simulator/device/CloudKit/export/share test had run on this Windows
host. macOS CI,
private development-container, App Store privacy report/answers, asset catalog,
Accessibility Inspector, and physical iPhone/iPad validation remain open gates.

## 2026-08-10 - Complete hosted Xcode and Simulator matrix

Scope: the complete pinned GitHub Actions workflow at commit
`aa18d6bbedfc4525208653a330dfe216636f5b01` after the final capture, library,
cloud-settings, accessibility-selector, and asynchronous UI-test reliability
repairs.

Authoritative run:

- https://github.com/PhilipN27/room-scanner/actions/runs/31359458769
- Job: `Static, package, build, and UI tests` (`93365277913`)
- Result: `success`
- Runner: macOS 15.7.7, Xcode 16.4 (`16F6`), iOS SDK 18.5
- Dynamically selected destinations: iPhone 16 and iPad (10th generation),
  each using the installed iOS 26.2 Simulator runtime

Observed green steps:

1. Host structural verifier and pure simulator-selector self-test.
2. Portable `RoomScanCore`: 122 tests, 0 failures.
3. Local Swift package resolution and unsigned generic iOS application build.
4. iPhone: 62 app tests and 25 UI tests, 0 failures; `TEST SUCCEEDED`.
5. iPad: 62 app tests and 25 UI tests, 0 failures; `TEST SUCCEEDED`.
6. XCTest result artifact upload.

This supersedes the preceding Phase-7 statement that the workflow had not run.
It is real macOS/Xcode/Simulator evidence, but it is not physical RoomPlan or
LiDAR evidence. Still open: Apple signing/archive validation; an owner-approved
privacy-policy URL and App Store Connect decisions; physical LiDAR iPhone/iPad
capture and permission paths; Accessibility Inspector/VoiceOver review;
CloudKit development-container account, upload, listing, recovery, cancellation,
and service-limit checks; independent ZIP/USDZ/PNG/PDF inspection; and system
share completion/cancellation.

## 2026-08-11 - Photoreal colored-mesh redesign

Scope: the approved photoreal colored-mesh design, including projection and
visibility math, frame analysis and calibration, deterministic texture baking,
mixed textured/fallback rendering, v3 derived caches, capture schema v3, and
the associated physical-device test contracts.

Focused TDD evidence:

- New projection, frame-analysis, visibility, coverage-fill, texture-baker,
  photoreal-cache, and colored-preview tests first failed against missing or
  incorrect production behavior, then passed after the corresponding changes.
- Safe mutation controls detected affine instead of reciprocal-depth
  interpolation, a reduced photometric-overlap floor, a relaxed coverage depth
  guard, a relaxed high-confidence LiDAR tolerance, disabled atlas dilation,
  bypassed sRGB decoding, non-Euclidean frame scoring, and disabled full-size
  checkerboard atlas sampling. Each live implementation was restored and its
  focused test rerun green.
- Restored focused RoomMesh sweep: 37 tests, 0 failures.

Fresh local verification:

1. Complete portable `RoomScanCore`: 160 tests, 0 failures.
2. Final iOS Simulator app-unit target: 86 tests, 0 failures; `TEST SUCCEEDED`.
3. Full iOS Simulator scheme: all 86 app tests passed; the 25-test UI target
   recorded one timing-sensitive failure in the pre-existing editor revision
   assertion (`revision-001` observed before `revision-002`). The exact failed
   UI test was rerun without code changes and passed, 1 test, 0 failures.
4. Unsigned generic iOS device build: `BUILD SUCCEEDED`.
5. Built-product byte inspection found `room_mesh_textured_fragment`,
   `scene-mesh-photoreal-v3`, `texture_valid`, and `exposureBias` in the device
   application binary.
6. Final whitespace, diff, and repository-status inspection completed without
   staging, committing, pushing, or opening a pull request.

These are source/build/Simulator results only. Still open and intentionally not
claimed: LiDAR-device subpixel RGB registration, 5 mm seam review, scan-health
latency and memory targets, thermal behavior, and photo-level visual quality.
The physical-device protocol and release gate remain in
`Docs/real-device-test-plan.md` and `Docs/release-checklist.md`.

## 2026-08-11 - Colored-mesh first-open hang regression

The first implementation built texture charts by comparing every projected
face against every other projected face. A focused 6,000-face regression took
8.13 seconds and failed its two-second boundedness oracle. Edge-indexed chart
construction reduced the same focused run to 0.03 seconds while preserving the
connected-chart/opposite-winding fixture.

Atlas padding was also changed from full `SIMD3<Double>` and native-`Int`
snapshots on every dilation pass to normalized linear UInt16 channels, Int32
owners, and deterministic frontier expansion. Negative controls proved the
chart-adjacency and compact-dilation tests fail when their live behavior is
neutralized.

Fresh restored verification: 9 texture-baker tests passed; complete
`RoomScanCore` passed 162 tests; the focused colored-mesh Simulator target
passed 5 tests; the complete RoomScanStudio app-unit target passed 86 tests;
and the unsigned generic iOS device build succeeded. A real captured room on a
physical LiDAR device remains the final latency and peak-memory oracle.

## 2026-08-11 - Measured colored-mesh progress and recovery UX

Scope: accurate measured progress for colored-mesh generation, cancellation,
30-second no-work detection, actionable failures, recoverable warnings, retry,
and stable accessibility wiring. The renderer alone publishes 100 percent so
the bar cannot claim completion before the textured mesh is ready.

Focused TDD evidence:

- Progress phase mapping, monotonic event sequencing, uncached and cached loader
  progress, cancellation without cache publication, recoverable fallback,
  controller completion ownership, stall timing, actionable errors, and stable
  accessibility identifiers each failed against absent or incorrect behavior
  before their production changes passed.
- Safe mutation controls changed the 30-second threshold to 31 seconds and
  prevented renderer readiness from reaching 100 percent. Both focused tests
  failed for the intended reason; the live behavior was restored and the
  surrounding viewer tests rerun green.
- Core atlas dilation work reporting and cancellation first failed against the
  old non-reporting signature, then passed with the cancellable implementation.

Fresh local verification:

1. Complete portable `RoomScanCore`: 163 tests, 0 failures.
2. Final iOS Simulator app-unit target: 94 tests, 0 failures, including 13
   `RoomMeshViewerAppTests`; `TEST SUCCEEDED`.
3. Full iOS Simulator scheme before the final accessibility-identifier-only
   correction: 93 app tests and 25 UI tests, 0 failures; `TEST SUCCEEDED`.
   After that correction, the focused identifier regression passed and the
   complete 94-test app-unit target passed as recorded above.
4. Final unsigned generic iOS device build with signing disabled:
   `BUILD SUCCEEDED`.
5. Final device-product inspection found `room_mesh_textured_fragment`,
   `scene-mesh-photoreal-v3.json`, `meshViewer.progress`,
   `meshViewer.percent`, `meshViewer.stall`, and `meshViewer.retry` in the
   application binary.
6. Final whitespace, diff, and repository-status inspection completed without
   staging, committing, pushing, or opening a pull request.

The Simulator cannot establish real-room progress pacing, cancellation latency
under device load, LiDAR registration, memory/thermal behavior, seam quality,
or photo-level appearance. Those remain physical-device gates in
`Docs/real-device-test-plan.md` and `Docs/release-checklist.md`.

## 2026-08-11 - Large-room colored-mesh analysis optimization

Scope: remove redundant linear-light conversion during 1,024-pixel sharpness
analysis and avoid exhaustive sample scans between photograph pairs that cannot
share the required photometric overlap. Frame eligibility, the 128-sample
threshold, robust ratios, calibration objective, image bounds, visibility,
atlas resolution, and cache format remain unchanged.

Focused red/green evidence:

- The original 1,024 x 768 sharpness workload took 0.90 seconds and failed its
  0.60-second core-operation bound. A 256-entry immutable sRGB-byte lookup and
  one-pass luminance buffer made the focused test pass. All 256 encoded values
  match the explicit sRGB transfer function within `1e-15`, and buffered
  sharpness matches the direct repeated formula within `1e-15`.
- The original 192-frame, 4,096-samples-per-frame unrelated-view calibration
  workload took 4.83 seconds and failed its two-second initial bound. Exact
  sample-range pruning plus a deterministic inverted occurrence index reduced
  the restored test to approximately 0.50-0.62 seconds under its final
  one-second bound. Existing robust-overlap, gain-clamp, anchor, and
  disconnected-frame tests remain green.
- Mutation controls replaced buffered sharpness with repeated nonlinear
  conversion (1.06 seconds, focused failure) and forced disjoint frames into
  the occurrence index (1.93 seconds, focused failure). Both optimized paths
  were restored and the complete frame-analysis suite passed 10 tests.

Fresh local verification:

1. Complete portable `RoomScanCore`: 167 tests, 0 failures.
2. Full iOS Simulator scheme: 94 app tests and 25 UI tests, 0 failures;
   `TEST SUCCEEDED`.
3. Final unsigned generic iOS device build with signing disabled:
   `BUILD SUCCEEDED`.
4. Device-product symbol inspection found
   `RoomMeshFrameAnalysis.luminanceSharpness`,
   `RoomMeshFrameAnalysis.solvePhotometricCalibration`, and
   `RoomMeshColor.sRGBToLinear`, plus `room_mesh_textured_fragment`,
   `scene-mesh-photoreal-v3.json`, and `meshViewer.progress`.
5. Final whitespace, diff, and repository-status inspection completed without
   staging, committing, pushing, or opening a pull request.

Host timing proves the redundant-work regressions and their local improvement;
it does not prove wall-clock speed, memory, or thermal behavior on a LiDAR
device. The updated physical-device plan requires a same-bundle phase-by-phase
comparison on the minimum supported device.

## 2026-08-11 - Adaptive background colored-mesh processing

Scope: one app-owned coloring worker, iOS 26 continued-processing admission,
foreground fallback, measured system progress, generation-scoped background
notifications, durable derived-state recovery, notification routing, and
viewer-independent progress/cancellation UI.

Focused TDD evidence:

- Capability, notification milestone, generation, atomic-record, recovery,
  one-worker, detach, expiration, cache-publication, relaunch, submission
  fallback, and cache-ready attachment tests first failed against missing or
  incorrect behavior and then passed after the corresponding production work.
- Mutation controls proved the 50-percent boundary, viewer-detach ownership,
  cache-publication success guard, and delivered-active-task recovery guard are
  exercised. Each focused test failed with its live guard neutralized, then
  passed after restoration.
- Final restored `RoomMeshColoringJobTests`: 14 tests, 0 failures.

Fresh local verification:

1. Complete portable `RoomScanCore`: 172 tests, 0 failures.
2. Full iOS Simulator scheme on iPhone 16 Pro / iOS 26.3.1: all 108 app tests
   passed; 24 of 25 UI tests passed. The sole failure was the existing
   capture-discard navigation timing assertion. Its exact test was rerun
   unchanged after removing disposable DerivedData that had filled the host
   volume and passed, 1 test, 0 failures.
3. Unsigned generic iOS device build with signing disabled: succeeded.
4. Built-product inspection found the wildcard continued-task identifier,
   `RoomMeshColoringJobCoordinator`, notification adapter/milestone symbols,
   `Room coloring is halfway done`, `room_mesh_textured_fragment`, and the
   `scene-mesh-photoreal-v3` asset names. Source/configuration inspection found
   no background-GPU resource request or entitlement.
5. Final whitespace, scoped diff, capture-ordering, and repository-status
   inspection completed without staging, committing, pushing, or opening a
   pull request. JPEG quality remains unchanged, and reconstruction remains
   enabled before scene depth is added after the observed mesh-anchor gate.

These results prove local policy, persistence, integration, Simulator UI, and
delivery wiring only. Scheduler admission, sustained background execution,
system progress UI, notification timing, force-quit behavior, battery/thermal
behavior, LiDAR registration, scan health, and photo-level quality remain the
physical-device gates in `Docs/real-device-test-plan.md`.

## 2026-08-12 - AI redesign platform Slice 0

Scope: feasibility and contract inventory, five strict v1 contract families,
malformed/cross-version fixtures, threat model, and a conditional hosted-service
ADR. No hosted service, account, credential, endpoint, entitlement, upload,
billing path, or production infrastructure was created. Private CloudKit
backup remained separate from future professional sync.

The required baseline was not initially green: static expectations were stale,
the project carried a team identifier, the masthead used a fixed display size,
and existing UI checks had off-screen/timing failures. Those baseline issues
were repaired without changing the redesign product boundary. A detached
worktree at exact commit `362c8cd862f38b1d159647d901ba75c6ef749efd`
contains the repairs but no redesign source, fixtures, or tests. Its final
oracles were:

1. Static verifier and simulator-selector self-test passed.
2. Portable `RoomScanCore`: 178 tests, 0 failures.
3. iPhone 16 Pro / iOS 26.3.1 Simulator: 120 app + 25 UI tests, 0 failures.
4. iPad (10th generation) / iOS 26.3.1 Simulator: 120 app + 25 UI tests,
   0 failures.
5. Exact package resolution and unsigned generic-device build succeeded with
   0 errors; the build input, objects, and linked symbols contain no redesign
   contract. The integrated build is the positive artifact control.

This proves baseline-source independence retrospectively. It is not rewritten
as a claim that the initially failing baseline passed earlier in wall-clock
time.

Focused redesign TDD first failed for absent types, then for unsupported source
schemas, canonical slash escaping, unsafe paths, missing Concept Set content
identity, duplicate JSON members, case/Unicode path aliases, and a filename-
only portal download description. Restored guards reject those cases before
typed materialization and validate actual bounded portal package archives.
Safe live mutations proved raw-default exclusion, exact AI/sync ledgers,
portal allowlisting, Concept attachment identity, and top-level decoder
protection are exercised. Final focused result: 27 tests, 0 failures.

The guest/offline oracle now combines two controls. An in-process iPhone
Simulator test bootstraps the real app environment and completes simulated
capture, explicit Save, local load/edit, actual legacy export preparation, and
lease cleanup; it passed 1/1. An explicit fail-fast transport catches a
deliberately injected HTTP request. Because global `URLProtocol` registration
did not intercept new default/ephemeral sessions on this Simulator, the static
production-boundary oracle separately rejects HTTP/auth/hosted clients and a
memory-only injected `URLSession` proves that detector fails closed. Future AI
package/import and physical Share Sheet paths are not claimed.

Fresh final integrated verification:

1. Static verifier, selector self-test, SDK arm64 iOS 18 type-check, and
   `git diff --check`: passed.
2. Complete portable `RoomScanCore`: 205 tests, 0 failures; focused redesign
   subset: 27/27.
3. iPhone 16 Pro / iOS 26.3.1 Simulator: 121 app + 25 UI tests, 0 failures;
   `/private/tmp/roomscanstudio-ai-redesign-final4-iphone.xcresult`.
4. iPad (10th generation) / iOS 26.3.1 Simulator: 121 app + 25 UI tests,
   0 failures;
   `/private/tmp/roomscanstudio-ai-redesign-final4-ipad.xcresult`.
5. Exact package resolution and unsigned generic-device build succeeded with
   0 errors. The build Swift file list and object output contain
   `RoomRedesignContracts`; linked symbols include the AI-package validator and
   portal snapshot types.
6. Same-family contract, security, integration, and final sign-off reviews
   ended with no high- or medium-severity finding. This got no cross-model pass.

An earlier full iPhone run was a useful red control: its long metadata lifecycle
completed after 64.096 seconds but exceeded the generic one-minute test
allowance; another two-launch test transiently failed app termination before an
automatic retry. The repaired focused pair passed, then both final full
matrices passed. Superseded in-flight Xcode runs were interrupted only after
later evidence changes; their resolved process trees exited and orphan checks
were clean.

Installed declarations and builds are not physical-device or hosted-service
evidence. RoomPlan/ARKit/LiDAR behavior, Face ID/passcode states, Share Sheet
destinations and lifecycle, hosted identity/authorization/revocation/deletion,
and representative operating cost remain explicit gates in the real-device
plan, release checklist, threat model, and ADR.

## 2026-08-12 - AI redesign platform Slice 1

Scope: additive spatial-truth/orientation v2 contracts, six deterministic
canonical cameras, Stage/Renovate/Reimagine intent and per-feature permissions,
Concept Set provenance, provider-neutral orientation readiness, nine semantic
presentations, and local property containers. Companion documents remain
separate from authoritative packages; existing revisions and fixtures are not
rewritten. No Slice 2 quality work or hosted workflow was added.

Red-green proof began with missing production APIs, then pinned the restored
canonical-camera digest at
`46c43c43604edf57dc8c35dc20ec8cef461ca9f3ce2b8249838d8ed733937edb`.
Focused Slice 1 Core passed 12/12; complete Core passed 217/217. Neutralizing
the live suggested-orientation guard made the intended negative test fail with
`XCTAssertThrowsError failed: did not throw an error`; restoring the guard made
all 8 surrounding spatial tests pass.

Fresh final local verification:

1. iPhone 16 Pro / iOS 26.3.1 Simulator: 123 app + 27 UI tests, 0 failures;
   `/private/tmp/RoomScanStudio-Slice1-iPhone-isolated-final-20260812-1855.xcresult`.
2. iPad (10th generation) / iOS 26.3.1 Simulator: 123 app + 27 UI tests,
   0 failures;
   `/private/tmp/RoomScanStudio-Slice1-iPad-isolated-final-20260812-1911.xcresult`.
3. The focused screenshot matrix passed on both form factors and retained all
   eight light/dark/default/accessibility attachments after a nonblank-frame
   oracle. Visual critique confirmed all nine semantic roles differ by name,
   symbol, border/pattern, selection treatment, accessibility text, and color.
4. Exact package resolution and the unsigned generic iOS build succeeded.
   Device-build inputs, objects, schema strings, and demangled symbols prove
   the new Core and app sources were delivered.
5. Static verifier and its hosted-client/weakened-guard controls, simulator
   selector self-test, guest offline oracle, and `git diff --check` passed.

One connected iPhone 17 Pro was unavailable and no physical iPad was present.
RoomPlan/ARKit/LiDAR suggestion quality and coordinate conventions therefore
remain unverified under the exact Slice 1 protocol in the real-device plan.
Slice 1 is locally complete but not complete end to end. This got no
cross-model pass.

## 2026-08-13 - Slice 1 device-discovered orientation-plan parity correction

An iPhone 17 Pro fresh capture proved that the orientation review's top-down
plan was vertically reflected relative to the semantic viewer. The root cause
was a display-only `+Z` convention mismatch; saved RoomPlan transforms were not
mutated. The default plan now uses viewer parity and display-only Rotate 90°,
Mirror, and Reset controls. An optional local presentation transform round
trips in the Slice 1 companion while canonical orientation, cameras, feature
IDs, captured geometry, measurements, evidence, lineage, coordinate epoch, and
revision bytes remain unchanged.

Fresh evidence from the final source state:

1. Complete Core: 220 tests, 0 failures; restored surrounding spatial suite:
   11 tests, 0 failures.
2. Complete app-unit target: 126 tests, 0 failures.
3. Strengthened orientation/property/semantic UI flow passed on iPhone and
   iPad, including rotate, mirror, save, reopen, persisted values, reset,
   property grouping, and all semantic roles.
4. Complete iPhone 16 Pro / iOS 26.3.1 Simulator scheme: 153/153.
5. Complete iPad (10th generation) / iOS 26.3.1 Simulator scheme: 153/153.
6. Package resolution and unsigned generic iOS build passed; built-artifact
   inspection contained `RoomTopDownPresentationTransform` and
   `RoomOrientationPlanDisplayTransform` symbols.
7. Guard mutation: removing the suggested-orientation guard made the focused
   negative test fail with `XCTAssertThrowsError failed: did not throw an
   error`; restoring it made the test pass. Static mutation controls detected
   both a weakened guard and an injected HTTP client. Simulator-selector
   self-test and `git diff --check` passed.
8. The normal static verifier reports only the intentionally local,
   uncommitted `DEVELOPMENT_TEAM` required for physical-device installation.

An earlier full iPad attempt is excluded: the host had only 116 MiB free, Xcode
timed out collecting Simulator diagnostics, and its result writer failed with
an I/O error. Only disposable RoomScanStudio DerivedData created by verification
was removed; the worktree and evidence files were untouched. The clean rerun
with adequate space passed 153/153.

The corrected UI still needs a physical iPhone parity/control/persistence
retest, and all Slice 1 behaviors remain required on a supported physical LiDAR
iPad. The user deferred the Norwalk YMCA example until the whole app is
complete. No Slice 2 code, hosted system, account, upload, or production change
was made.

## 2026-08-13 - AI redesign platform Slice 2

Implemented provider-neutral, revision/epoch-bound quality records for visual
sharpness, spatial/visual coverage, AR tracking, and semantic identification
confidence. The optional immutable-revision report preserves legacy decoding;
post-stop analysis reuses posed keyframes and existing sharpness scoring while
the live path remains scalar/pose-only. The app adds bounded deduplicated
coaching, patterned accessible overlays, advisory Finish review, exact explicit
Save Anyway provenance, and reopened quality summary. The future carrier is a
contract hook only; no Slice 3 archive or hosted route was added.

Red-green and mutation proof: missing APIs failed compilation; the canonical
golden placeholder failed with digest
`f5757df1fc17596c3b3ab47fc63709a4bca2bafd3d5dc48f36990beedd63ab36`.
Neutralizing both weak-Finish/save checks failed the focused coordinator test;
neutralizing required acknowledgement failed the Core throw assertion.
Restored focused tests passed. Static controls detected injected live
`luminanceSharpness` and injected production `URLSession` calls.

Fresh final evidence:

1. Complete Core 230/230; quality tests 10/10; complete app-unit target
   131/131.
2. Complete iPhone 16 Pro / iOS 26.3.1 Simulator scheme 160/160 at
   `/private/tmp/RoomScanStudio-Slice2-iPhone-full.xcresult`.
3. Complete iPad (10th generation) / iOS 26.3.1 Simulator scheme 160/160 at
   `/private/tmp/RoomScanStudio-Slice2-iPad-full.xcresult`.
4. Focused screenshot runs passed with 16 retained images per form factor over
   four states, light/dark, and default/accessibility XXXL Dynamic Type.
5. Exact package resolution, unsigned generic iOS build, built-artifact
   source/schema/symbol inspection, selector self-test, `git diff --check`, and
   all non-signing static checks passed. Branch/HEAD remained exact and the
   staged diff was empty. The ordinary verifier reports only the preserved
   local `DEVELOPMENT_TEAM`.

At this checkpoint, the paired iPhone 17 Pro was unavailable and no physical
iPad was present. Controlled physical Slice 2 iPhone behavior therefore
remained unverified. Physical iPad was owner-waived and explicitly unverified.
The Norwalk YMCA example remained deferred. No external system changed,
nothing was staged or committed, and Slice 3 had not started at this
checkpoint. Full evidence is in
`Docs/evidence/2026-08-13-ai-redesign-slice-2-verification.md`.

## 2026-08-16 - Slice 2 physical-iPhone owner-acceptance reconciliation

The owner accepts Slice 2 on the physical LiDAR iPhone based on direct
observation. The retained physical evidence is limited to three screenshots;
it is not a complete independent artifact/device-metadata matrix for the
seven-case protocol. This records owner acceptance without claiming that exact
region/evidence, Finish, Save Anyway, and reopen results can be independently
reproduced from retained artifacts. The generic `regions` label and repeated
tracking guidance remain known limitations.

Physical iPad remains owner-waived and unverified, not passed or failed. The
Norwalk YMCA example remains deferred until the entire application is complete.
This reconciliation changes documentation only and does not change Slice 2
code. Slice 3 work is governed by
`Docs/superpowers/plans/2026-08-16-ai-redesign-platform-slice-3.md`.

## 2026-08-17 - AI redesign platform Slice 3 (local/Simulator complete)

Slice 3 completes the local/offline AI Room Package, disclosure review, Share
Sheet preparation/cleanup, and revision-bound Concept Set scope. It adds no
hosted provider call, account, upload, direct-chat insertion, or Slice 4 work.

Fresh final local/Simulator evidence is recorded in
`Docs/evidence/2026-08-17-ai-redesign-slice-3-verification.md`:

1. Complete `RoomScanCore` passed 266/266 tests.
2. The complete Xcode scheme passed 219/219 on each iPhone 16 Pro and iPad
   (10th generation) Simulator: 185 app tests and 34 UI tests per form factor.
3. The final focused Slice 3 UI evidence passed 5/5 on each form factor.
4. Deterministic AI-ready and Complete production archives independently
   extracted and closed their canonical manifest, ledger, digest, and source/
   profile bindings before becoming shareable.
5. Concept automatic mapping required an authenticated finalized-package binding
   (the exact local canonical manifest and complete view ledger, not account
   authentication); otherwise it remained manual or unmatched. The local Share
   Sheet lifecycle cleaned only its exact owned lease.
6. The scoped production AIRedesign path has no provider/model/authentication/
   direct-HTTP client. This is not a claim that the entire target is
   network-free: explicit private CloudKit backup remains separately scoped.
7. The known pre-existing ordinary static-verifier exception remains local
   `DEVELOPMENT_TEAM`; it is not a Slice 3 change or release approval.

The supported physical LiDAR iPhone was unavailable, so physical Share Sheet,
Files/AirDrop/external-app handoff, actual device media import, and device
lease-cleanup behavior remain unverified. All physical-iPad checks remain
waived and unverified. Current external-provider behavior, privacy/account
terms, instruction following, and output quality are unverified. Slice 4 and
later checklists remain unchecked.

## 2026-08-19 — Slice 4 professional-service documentation checkpoint

Slice 4 introduces the optional/default-off professional-service foundation;
it does not add Slice 5 project synchronization, Slice 6 portal/publication
product behavior, or Slice 7 production lifecycle/release behavior. The
dedicated evidence ledger is
`Docs/evidence/2026-08-19-ai-redesign-slice-4-verification.md`.

This checkpoint records accepted lane evidence without inventing a whole-slice
completion result:

1. Task 1 authentication/identity/session domain: 97/97.
2. Task 5 focused policy/billing: 73/73; the controller's clean pre-final shared
   service checkpoint was 178/178, superseding the stale 179 count in its
   original report.
3. Task 6 provider/API adapters under Node 24.15.0: 35/35 focused and 205/205
   clean full service, zero failures/suites; typecheck and clean declaration/
   JavaScript build exited 0. Built evidence proved scanner GET 200 → deliberate
   POST 200 with server-derived `apigw:artifact-click-1`, missing Stripe content
   type 400, and 14/14 manifest/OpenAPI parity.
4. The 32 emitted adapter/handler/contract `.js`/`.d.ts` artifacts have
   aggregate SHA-256
   `fca16e9d305ab5f6127516a8f40ef38ab94391f1f7d1e31f770bf073e53f5c30`;
   serialized OpenAPI was 9,398 bytes. Credential/raw-SQL/later-route scans were
   clean.
5. The final compiled-only Cognito mutation bypassed the atomic challenge
   session-issuance port; both focused controls failed (0/2), and a clean build
   restored them. Earlier adapter mutations and red→green outputs remain in the
   Task 6 report.
6. Accepted PostgreSQL 16.13 `0001`–`0006` evidence records 53/53 integration
   cases, 166 malformed auth cases, forced RLS/ACL/pool reuse and 14/14 restored
   auth-persistence mutations. Staged `0007` checkpoints A–D are green, but the
   frozen full catalog/mutation/integration acceptance is pending.
7. Offline infrastructure lane: 56/56 tests, 16/16 mutation restorations, 154
   synthesized resources, 31 outputs and eight inspected Node 24 Lambda assets;
   no AWS call/deployment.
8. iOS professional/default-off lane: 26/26 focused Simulator tests plus clean
   build/artifact inspection. Physical Face ID/passcode remains unverified.
9. CI/static tools: 12/12 unit tests and guest-network/structured-secret scans
   passed; final top-level SBOM/artifact outputs remain pending a frozen run.

No AWS, Apple, Cognito, SES, Stripe, DNS, hosting, email or CloudKit account/
resource was created or changed; no credential was created/rotated; no endpoint
was deployed; no production/shared database or customer/room/biometric/GPS/
billing data was used; and no commit, push, PR or merge occurred. The only
database mutation was the explicitly authorized disposable local PostgreSQL
role/schema/function test work.

Required status at this checkpoint:

- local implementation: **incomplete pending frozen composition/acceptance**;
- local PostgreSQL/integration: **incomplete for the whole slice**;
- non-production provider/infrastructure: **incomplete**;
- physical Face ID: **incomplete**;
- production provisioning/release: **pending**.

Rollback disables `professional_sign_in_enabled`,
`hosted_operations_enabled`, and `publication_enabled`, revokes affected app
sessions and restores approved immutable Lambda aliases while preserving local
packages, AI Room Package export, Concept Sets, legacy export and Share Sheet
behavior. Immediate portal-link revocation remains Slice 6; full deletion/
restore/backup lifecycle remains Slice 7.

## 2026-08-21 — Slice 4 local closure reconciliation

This dated addendum supersedes the 2026-08-19 *current-state* summary without
rewriting its historical commands, counts or hashes. It records only results
supplied by the current controller/authority reviews. Documentation searches
and diff checks are the only commands run for this addendum itself.

### Current verified local lanes

1. Hosted service used Node 24.15.0. From `HostedService`, the clean sequence
   `npm run typecheck && npm test && npm run build` passed: typecheck, **277/277
   tests**, and build. Emitted route inspection found OpenAPI/manifest version
   `roomscan-slice4-routes-v3` with **19 paths / 19 routes**. Accepted proof
   records pre-resolution context clearing. No current aggregate service hash
   is claimed; the final umbrella artifact manifest will provide per-file
   hashes.
2. From `HostedService/db`, the exact accepted command was:

   ```sh
   env PATH=/Users/philipnora/.nvm/versions/node/v24.15.0/bin:/opt/homebrew/opt/postgresql@16/bin:/usr/local/bin:/usr/bin:/bin npm test
   ```

   It passed all **43 commands**, **53/53** integration cases, **14/14** legacy
   mutations and **46/46** `0007` mutations. Catalog proof records seven
   `LOGIN NOINHERIT NOBYPASSRLS` runtime roles and no role-membership/`SET ROLE`
   authority edges. Every disposable cluster reported no surviving process,
   removed its temporary root and rejected TCP. The accepted `0007` SHA-256 is
   `c2a3af7db980d3d32933f008c17da6b68e8bdf94408e10c8bc694c5968841030`.
3. From `HostedService/infra`, the synthetic-only `npm run verify` lane passed
   **103/103** tests and **16/16** restored mutations. Artifact inspection found
   exactly nine manifest assets across **28 files**, complete migration,
   VPC and IAM roots, no orphan/stub markers, and no Slice 7 resources. No AWS
   credential or provider call was used.

### Current immutable hashes

| Item | SHA-256 or exact asset ID |
| --- | --- |
| synthesized template | `488efce8596d921d95b7e1f2d7200b09c2538f66f63c1d82a1271f8e05464f11` |
| assets manifest | `281237aa9507d7cde711628d041b471694c4234b36bb7f019ccc69a705c53848` |
| artifact-inspection evidence | `17c6b87ebc690b26c22d91aaa9bce191d5cb3b12c411e4945d80bb0e0ed10915` |
| migration asset directory | `asset.1b9fa2385d0bf4ba98694e268c7c852a82e6ec6c3047135191e244d6ffc4798a` |
| migration operator index | `c32b3118a9a7bf12557bf22888ff5663aed28d6be097d49239044fa85bf7de2c` |
| migration runner | `4997808a9a8cd13937e6bb7f6f72a414250acde822c651c1f25ebc433da47acf` |
| migration manifest | `26e9cccd080979b3d57d2f88be6debff7184ab1a61f5d1fedf038fb3997c46c9` |
| migration CA bundle | `e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3` |
| migration `0001` | `9b4fbd3e2e07c327dcfe226a8de118b789d2ee173c85a2e537dd3c128967264b` |
| migration `0002` | `ad468112d8705b4f96cc9cb4c2f2d4bc01214b01b11bb30b057a9e4ab6dc3187` |
| migration `0003` | `0875c1ac73b6e25207dcf885ef5f8df7ee912d815385519cf7a6b796a9ea0d6a` |
| migration `0004` | `82c11e83e588b964a1dd07c05d1d092f040fe940c92307a7b93cf69b5f583fb8` |
| migration `0005` | `3546e39eb8b8e9685a0c48f418dbcf3b6817666e232ecd2b9d0b412be75f7f29` |
| migration `0006` | `1227036e53acf3709ccb4fa472e2b40a796eb7dcd8083a40304453be3b0e4250` |
| migration `0007` | `c2a3af7db980d3d32933f008c17da6b68e8bdf94408e10c8bc694c5968841030` |

### Pending local proof slots

Current source predicts **266 Core tests** and **259 tests per full iPhone/iPad
Simulator scheme**: 225 app-unit tests, including 32
`ProfessionalBoundaryTests` and eight `MagicLinkCompletionTests`, plus 34 UI
tests. These are source expectations only. Fill these slots only from fresh
commands/xcresults supplied by the controller:

- Core command/result/duration: `PENDING`;
- full iPhone destination, command, count and xcresult SHA-256: `PENDING`;
- full iPad destination, command, count and xcresult SHA-256: `PENDING`;
- 32-test professional-boundary selector/result/xcresult: `PENDING`;
- eight-test magic-completion selector/result/xcresult: `PENDING`;
- DEBUG-only physical harness build/artifact inspection: `PENDING`;
- full umbrella result at `.artifacts/slice4-hosted/verification.json`: `PENDING`;
- `.artifacts/slice4-hosted/sbom.cdx.json` and SHA-256: `PENDING`;
- `.artifacts/slice4-hosted/artifact-manifest.json` and SHA-256: `PENDING`;
- per-step log inventory/digests and current service per-file hashes: `PENDING`;
- separately provisioned cross-model verdict: `PENDING`.

### Formal status and action boundary

1. Local implementation: **pending final proof** listed above.
2. Local PostgreSQL: **complete** for the disposable PostgreSQL scope.
3. Provider/infrastructure: **external evidence pending authorization**.
4. Physical Face ID/passcode: **pending owner worksheet**.
5. Production provisioning/release: **pending by design**.

The repository is not production-ready or release-approved. This
reconciliation performed no AWS, Apple, Cognito, SES, Stripe, DNS, email,
hosting or CloudKit action, used no real customer/room/biometric/GPS/email/
billing data or credential, added no Slice 5 implementation or Slice 7
resource, and made no commit, push, PR or deployment.

## 2026-08-21 — fresh Slice 4 closure evidence follow-up

This follow-up advances only the current local-implementation proof. It
preserves the preceding addendum as the state before these executions.

### Hosted umbrella

Exact repository-root command:

```sh
python3 -B Scripts/verify_slice4_hosted.py \
  --artifacts-dir .artifacts/slice4-hosted-final
```

Result under Node v24.15.0: **exit 0 / PASS, 13 steps**. Generated evidence:

| Artifact | Exact result | SHA-256 |
| --- | --- | --- |
| `.artifacts/slice4-hosted-final/verification.json` | terminal PASS / 13 steps | `52c7bc7dcbb6879b05b2115870cba641f10272e190930a428a315e7fb7a84074` |
| `.artifacts/slice4-hosted-final/sbom.cdx.json` | CycloneDX 1.6; 148 components = 145 libraries + 3 lockfiles | `d0c07261c0149dfa63c1a8083a0247ab64de9f28873151bfec3a4ba7312e175e` |
| `.artifacts/slice4-hosted-final/artifact-manifest.json` | 128 files; secret scan PASS | `99aebd447b5984adb8204ae055298dcae56c3b21b4467bad5d650cee09e380b3` |
| final infrastructure artifact-inspection evidence | template/assets hashes unchanged | `eeb64e6fe51049b9330f04bd2e8215068c33327e77a8ca70770094af9144a762` |

The current template remains
`488efce8596d921d95b7e1f2d7200b09c2538f66f63c1d82a1271f8e05464f11`;
the assets manifest remains
`281237aa9507d7cde711628d041b471694c4234b36bb7f019ccc69a705c53848`.

### Fresh Core

From `RoomScanCore`, the first sandboxed attempt failed only because the sandbox
denied `~/.cache/clang`. The exact same command was then authorized outside that
sandbox and passed **266/266 with zero failures**:

```sh
swift test --package-path . \
  --scratch-path /private/tmp/roomscan-slice4-closure-core \
  --disable-sandbox --no-parallel
```

The initial permission failure is not a product-test failure and is not counted
as a green run.

### Fresh full iPhone Simulator

Exact repository-root command:

```sh
xcodebuild -project RoomScanStudio.xcodeproj \
  -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=B8FBE9EA-81AD-4134-BC1D-A67A7747271E' \
  -derivedDataPath /private/tmp/roomscan-slice4-closure-full-iphone-derived \
  -resultBundlePath /private/tmp/roomscan-slice4-closure-full-iphone.xcresult \
  -clonedSourcePackagesDirPath /Users/philipnora/Library/Developer/Xcode/DerivedData/RoomScanStudio-dkbducgrejgtngdaiombjiuygbrs/SourcePackages \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO test
```

The iPhone 16 Pro Simulator on iOS 26.3.1 build 23D8133 passed **259/259** with
zero failed, skipped or expected tests: 225 app-unit plus 34 UI tests. The
xcresult is
`/private/tmp/roomscan-slice4-closure-full-iphone.xcresult`; its deterministic
manifest SHA-256 is
`fd96cff96dec26c466695745f63cd202f4e69def1ff841af7a3b473bf96dec98`.
The exported tests JSON SHA-256 is
`c0e082197fd690f1fde419e66377146e2f0b7ba89401d834d4641725f6cc0398`.

### Bounded cross-model review

Terra reviewed the service/infrastructure boundary and the iOS/documentation
boundary. Final re-review reported no Critical or Important finding. One
Important worksheet finding was corrected by requiring the exact physical RVI/
`tcpdump` packet capture, owner-controlled positive canary, marked guest window
and cleanup now recorded in `Docs/real-device-test-plan.md`; Terra re-reviewed
that correction. This is bounded cross-model review, not certification or an
independent security audit.

### Remaining local-implementation slots

- full iPad command/result/xcresult and hashes: `PENDING`;
- focused 32-test professional-boundary result/xcresult and hashes: `PENDING`;
- focused eight-test magic-completion result/xcresult and hashes: `PENDING`;
- final DEBUG built-app artifact inspection and hashes: `PENDING`;
- final documentation search/diff closure: `PENDING`.

Formal status 1 therefore remains **local implementation pending final proof**.
Statuses 2–5 are unchanged: local PostgreSQL complete; external provider/
infrastructure evidence pending authorization; physical Face ID/passcode
pending owner worksheet; production provisioning/release pending by design.
No external action, real data, Slice 5 implementation, Slice 7 resource,
commit, push, PR or deployment is claimed, and the repository remains not
production-ready or release-approved.

## 2026-08-21 — final local iOS/artifact/static closure

This final local follow-up closes the remaining status-1 implementation slots.
The controller retains a final diff/docs/cleanup handoff audit; that audit is
not an unrun implementation matrix.

### Complete iPad scheme

Exact repository-root command:

```sh
xcodebuild -project RoomScanStudio.xcodeproj \
  -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=FDDEC0DB-DB75-4FBA-8344-69E2A2819531' \
  -derivedDataPath /private/tmp/roomscan-slice4-closure-full-ipad-derived \
  -resultBundlePath /private/tmp/roomscan-slice4-closure-full-ipad.xcresult \
  -clonedSourcePackagesDirPath /Users/philipnora/Library/Developer/Xcode/DerivedData/RoomScanStudio-dkbducgrejgtngdaiombjiuygbrs/SourcePackages \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO test
```

The iPad (10th generation) Simulator on iOS 26.3.1 build 23D8133 passed
**259/259**, zero failed/skipped/expected: 225 app-unit plus 34 UI tests.

```text
/private/tmp/roomscan-slice4-closure-full-ipad.xcresult
b07196c43c9b37ba818ca0eb4a810d29b9ad98473e772932c9c16812c0a290f8  xcresult deterministic manifest
/private/tmp/roomscan-slice4-closure-full-ipad-tests.json
0d75a26f8f6474b8bf2cdcf2d1956ad544f0623e49ef93545feac01adf411d11  exported tests JSON
```

### Focused professional and magic-completion boundaries

Exact professional command:

```sh
xcodebuild -project RoomScanStudio.xcodeproj \
  -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=B8FBE9EA-81AD-4134-BC1D-A67A7747271E' \
  -derivedDataPath /private/tmp/roomscan-slice4-closure-professional-derived \
  -resultBundlePath /private/tmp/roomscan-slice4-closure-professional.xcresult \
  -clonedSourcePackagesDirPath /Users/philipnora/Library/Developer/Xcode/DerivedData/RoomScanStudio-dkbducgrejgtngdaiombjiuygbrs/SourcePackages \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  -only-testing:RoomScanStudioTests/ProfessionalBoundaryTests \
  -quiet test
```

Result on iPhone 16 Pro / iOS 26.3.1: **32/32 passed**.

```text
/private/tmp/roomscan-slice4-closure-professional.xcresult
03c794f295598266f33eefe2f8378ea1e7ec0cd5a15416ae04172a5e98304720  xcresult deterministic manifest
/private/tmp/roomscan-slice4-closure-professional-tests.json
d3471339e4a162dbdf600002d1f2f6decefcd359d219e7b5edd0d13e0b51fb64  exported tests JSON
```

Exact magic-completion command:

```sh
xcodebuild -project RoomScanStudio.xcodeproj \
  -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,id=B8FBE9EA-81AD-4134-BC1D-A67A7747271E' \
  -derivedDataPath /private/tmp/roomscan-slice4-closure-magic-derived \
  -resultBundlePath /private/tmp/roomscan-slice4-closure-magic.xcresult \
  -clonedSourcePackagesDirPath /Users/philipnora/Library/Developer/Xcode/DerivedData/RoomScanStudio-dkbducgrejgtngdaiombjiuygbrs/SourcePackages \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  -only-testing:RoomScanStudioTests/MagicLinkCompletionTests \
  -quiet test
```

Result on iPhone 16 Pro / iOS 26.3.1: **8/8 passed**.

```text
/private/tmp/roomscan-slice4-closure-magic.xcresult
5abf20d4e407e304e30cb98d63c0678797d9f78f1828ec9a8b465d0953ec63b7  xcresult deterministic manifest
/private/tmp/roomscan-slice4-closure-magic-tests.json
50902cb532234454efa1cd95589c38686302d9e8cdd15c870442149eedae601d  exported tests JSON
```

### Artifact and configuration separation

The fresh clean Simulator artifact build passed. Inspector evidence at
`/private/tmp/roomscan-slice4-closure-artifact-inspection.json` has SHA-256
`8306aae8bf23d571fc25bc323c41c931099ecd74edebfb9b86bf225d05f63277`.
It records bundle `org.roomscanstudio.app`, Face ID PASS,
`missingSymbols=[]`, 9/9 professional symbols, 2/2 magic symbols, the physical-
harness symbol present, and:

```text
00cb6f2c850162f3a3a4c7449ca2764201c93698ca967e824f1ea89a5f5b34b8  Simulator launcher
2bdd4dffe3b393c29c3c71d0780f2e50e0a089c6863dd0b2356a7139457ee662  Simulator DEBUG dylib
4ae82118854e21adc8f99a293babc10427f77c27d44a36b60a84e196a7ce441f  Simulator app manifest
```

Built `NSFaceIDUsageDescription` is exactly: “RoomScanStudio uses Face ID or
your device passcode only when you unlock a professional workspace or confirm a
sensitive professional action.” Inspection found zero forbidden package
entries, vendor-linked images, Associated Domains or credential canaries.

Unsigned generic arm64 device Debug and Release builds both passed. The
physical-harness marker, flag and type are present in Debug and all absent from
Release:

```text
1b0ea78ce64ba120fcc74b5baa9da2fa73400d1cdf1e4e1fafe07faf41dcc7e5  generic Debug app manifest
765c241f7cca62bc7f4f0ec8effaa9dc6454db2d8078ab34d3439daf2f6d9c7d  generic Release app manifest
```

Scoped Slice 4 static controls passed with both detector positive controls, and
the Python suite passed **30/30**. Direct
`python3 -B Scripts/verify_xcode_scaffold.py` ended with exactly the documented
pre-existing `DEVELOPMENT_TEAM` exception; it is not reported as a green full
scanner. Generated Python bytecode/cache was removed and confirmed absent.

### Final formal status

1. Local implementation: **complete**.
2. Local PostgreSQL: **complete**.
3. Provider/infrastructure: **external evidence pending authorization**.
4. Physical Face ID/passcode: **pending owner worksheet**.
5. Production provisioning/release: **pending by design**.

Local completion is not production readiness or release approval. No external
action, real data, credential, Slice 5 implementation, Slice 7 resource,
commit, push, PR or deployment is claimed.

## 2026-08-21 — post-closure IAM least-privilege repair

The final infrastructure review found an unconditional Lambda-role
`kms:Decrypt` grant on the SecretsKey. The repair removes that grant and adds an
exact Secrets Manager `ViaService` + `SecretARN` synth oracle plus a mutation.
The focused live test was observed failing RED against the pre-fix policy and
passing GREEN after the repair; this was not an analysis-only hypothetical.

Direct post-fix platform command from `HostedService/infra` under Node
v24.15.0:

```sh
PATH=/Users/philipnora/.nvm/versions/node/v24.15.0/bin:$PATH \
  node --test .test-dist/test/*.test.js
```

Result: **104 tests, 104 passed; fail/cancel/skip/todo all zero**. Full
`npm run verify` under Node v24.15.0 passed, including **17/17** restored
mutations.

Before the fresh umbrella rerun, the controller identified and cleared exactly
31 stale, unattached 56-byte PostgreSQL shared-memory segments left by prior
disposable tests. The active Homebrew PostgreSQL segment was identified
separately and left untouched. Exact umbrella command:

```sh
python3 -B Scripts/verify_slice4_hosted.py \
  --artifacts-dir .artifacts/slice4-hosted-final
```

Result: **Node v24.15.0, 13 steps, exit 0 / PASS**.

### Current post-fix hashes

```text
7bdc0b5cea360e6ed61622ac81ce42f8e637a86ec4a5426779af4f4bc7adbda4  .artifacts/slice4-hosted-final/verification.json
d0c07261c0149dfa63c1a8083a0247ab64de9f28873151bfec3a4ba7312e175e  .artifacts/slice4-hosted-final/sbom.cdx.json
42b2679d33b239185d73ed096302bd0e33f319f22361858acd26e6cf1789a878  .artifacts/slice4-hosted-final/artifact-manifest.json
9309d2c294b9672ddc9e83462c658401acb5c5523cefac20b5cfdd7b5b3a7b12  synthesized template
b45dbd74005db34ba2c1c4a4b7f086e04f4043e5a3033edb75b9757a8d013030  assets manifest
58d299972076259525d17bc24ea010f5133ab048153fce2f7936cf142465c303  infrastructure artifact-inspection evidence
```

The SBOM digest is unchanged. It remains CycloneDX 1.6 with 148 components
(145 libraries and three lockfiles). The new artifact manifest still closes
128 files and its secret scan passed.

Exact successful step-output digests:

```text
a7981ca0ab7e5877f9876cacf257f4f860046c48d6bb76ec11abc6b243b527df  service tests
996ca17815680dca391c30ab50f17b2b7c46a27514d78447fe0702d508d944c2  PostgreSQL
6c2a36563871c6cb6e4ec112537e4556f831088ce78d33d166ea623146589003  infrastructure assertions
2ca27656605e1402327da3b7269cb56d5686f8ef562a40e1657bf2228c9f7833  infrastructure mutations
295b0f111aa3449f6181d3b68367dc8cb9d0bda55cfd95603298360510f45d05  synth / artifact inspection
```

Formal statuses are unchanged: local implementation and local PostgreSQL are
complete; external provider/infrastructure evidence and physical Face ID/
passcode remain pending; production provisioning/release remains pending by
design. Offline synth proof is not live IAM/KMS evidence. No external action,
real data, credential, Slice 5 implementation, Slice 7 resource, commit, push,
PR or deployment is claimed.
