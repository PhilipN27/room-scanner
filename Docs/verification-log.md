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

The Phase 7 CI workflow is authored but has not run. No Swift/Xcode/Simulator/
device/CloudKit/export/share test has run on this Windows host. macOS CI,
private development-container, App Store privacy report/answers, asset catalog,
Accessibility Inspector, and physical iPhone/iPad validation remain open gates.
