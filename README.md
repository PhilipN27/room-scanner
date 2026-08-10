# RoomScanStudio

RoomScanStudio is a native iPhone and iPad room-documentation project. Phase 1
adds an offline local room library backed by authoritative file packages, with a
rebuildable local SwiftData index and an explicit deterministic mock-review
path. Phase 2A adds Foundation-level capture contracts and evidence storage.
Phase 2B adds a compile-intended iOS 17 RoomPlan adapter beside a deterministic
simulator/test driver, explicit capture coordination, and a black semantic
Canvas. Phase 2B itself did not add a rescan route, alternate export formats,
CloudKit, a server, accounts, or analytics.

Phase 3 V1-A adds only a deterministic-fixture rescan proposal/revision path.
It does not add live master rescans, ARWorldMap persistence, mesh fusion,
alternate export formats, CloudKit, a server, accounts, or analytics.

Phase 4 adds a saved-room, non-AR semantic-box viewer and an optimistic
copy-on-write editor. It does not add a live AR viewer, fabricated mesh/USDZ
rendering, capture changes, CloudKit, or export formats.

Phase 5 adds an explicit, inspectable head-revision export. It is not a backup
or full-history archive: it freezes only the current head's canonical data,
referenced assets, declared evidence, and bounded derived summaries into a
classic deterministic ZIP. It does not add CloudKit, a server, accounts,
analytics, a ModelIO converter, GLB/OBJ/PLY output, or a claim that export has
been inspected on an Apple platform.

Phase 6 adds an explicitly user-triggered, private-CloudKit full-project
snapshot backup/recovery path. It is off by default, local use remains
offline-capable, and it is not background synchronization, a source-of-truth
migration, subscriptions, simultaneous editing, or iCloud Documents. No
CloudKit call occurs at launch or merely when the local preference changes.

## Phase-1 library through Phase-6 backup status

The repository now contains:

- a classic-group Xcode project with RoomScanStudio, XCTest, and XCUITest
  targets; iOS 17.0; iPhone and iPad support; a shared scheme; no active team,
  provisioning profile, iCloud entitlement, or CloudKit capability;
- a repository-root local Swift package dependency named `RoomScanCore`, used
  by the app and unit-test targets without duplicating store behavior;
- Foundation-only domain models and `LocalRoomProjectStore`: validated stable
  identifiers and relative paths, file-backed assets, deterministic
  Save/Discard, immutable revision lineage, staged writes, pending-marker
  recovery, same-process writer serialization, stored-lineage validation,
  canonical effective freshness, spatial/provenance and mobility-placement
  validation, per-revision evidence manifests with streamed SHA-256 digests
  and exact evidence-directory closure, symlink rejection, and corrupt package
  isolation during listing;
- a pure attempt-token capture reducer and atomic `commitInitialCapture` API:
  save is emitted only from review, stale callbacks are ignored, retryable
  processing failure returns to a reviewable flow, and Discard before Save is
  accepted performs no identifier generation, root creation, asset read, or
  store-save effect. `.saving` is deliberately non-cancelable because its
  explicit Save may already be promoting a package; UI must hide or disable
  Discard then, and a save failure returns to review where Discard is legal.
  The Foundation-only state model carries qualitative RoomPlan coaching/error
  and ARKit tracking mirrors, tokenized optional GPS, and a single in-flight
  reference-photo request that is legal only while scanning and blocks Stop;
- a SwiftData `RoomProjectIndexRecord` used only as a rebuildable local search
  index. Its `ModelConfiguration` explicitly specifies both
  `groupContainer: .none` and `cloudKitDatabase: .none`;
- an active/archived library, profile metadata editor, duplicate,
  archive/unarchive, confirmed permanent delete, revision inspection, and
  restore-as-new-revision actions;
- an explicit MockRoom-v1 review path. It never creates a profile until Save;
  Discard returns without persistence;
- a Phase-2B capture route. `RoomCaptureSession.isSupported` remains the sole
  live-capture gate; scene mesh is an optional raw-evidence status, not a
  second gate. The production iOS adapter constructs one app-owned `ARSession`
  per leased driver and injects it into `RoomCaptureSession`; it never runs or
  delegates the AR session itself, and it creates no AVCapture session, picker,
  or second camera owner. Camera permission follows explicit Prepare; optional
  one-shot GPS follows an explicit request and is cancelled/awaited by attempt
  before terminal routing. The route uses attempt-local scratch
  outside the project-package root, an explicit Prepare/Start/Stop/Review/Save/
  Discard reducer flow, and a black normalized-semantic Canvas.
  `--use-simulated-capture` still injects only a deterministic fixture-evidence
  driver for UI tests. The real adapter writes raw and processed RoomPlan JSON,
  native USDZ, a generated thumbnail, and same-session reference photos into
  scratch before review; raw mesh and world map remain honest omissions. It
  stops with `pauseARSession: true` for V1 privacy, so future rescan work cannot
  assume coordinate continuity. RoomPlan delta callbacks do not replace the
  full Canvas snapshot; only `didUpdate` does. The review snapshot becomes
  authoritative when processing completes, later live snapshots are ignored,
  and a discard waits for tracked scratch writers plus the driver barrier and
  final RoomPlan end callback before removal. The
  single-scene V1 environment leases one coordinator/driver per active attempt;
  scratch roots and attempt leaves reject symbolic links, orphan recovery
  removes only owned attempt directories, and a cleanup failure remains
  actionable rather than routing away;
- a Phase-3 V1-A fixture-only rescan flow. The exact safety boundary is:
  “A rescan candidate is valid only if one of these registrations is proven: 1.
  continuous capture in the original app-owned ARSession, or 2. successful
  relocalization against a recorded ARWorldMap.” The V1 production path is
  deliberately unavailable because the final privacy stop ends continuity and
  no world map is recorded. Only `--use-deterministic-rescan-fixture` enables
  a typed bundled sidecar. Its full candidate must exactly and bijectively match
  the base semantic layers and kinds; it preserves base IDs while replacing only
  candidate geometry/provenance, preserves annotations/measurements/photos,
  labels measurements unchanged and unrevalidated, and writes one immutable
  `.rescan` child only through the locked store-owned acceptance transaction.
  Undo is transient; a later Revert remains an immutable child. Generic rescan
  append, candidate additions/deletions, and any live registration claim fail
  closed;
- a Phase-4 saved-room viewer and editor. The viewer uses a fully virtual,
  non-AR RealityKit surface with an explicit perspective camera and disposable
  semantic bounding boxes; it does not start/configure an AR session or request
  camera access. Orbit/no-clip controls, root visibility toggles, photo-pose
  markers, and display-only thickness for planar surfaces are not survey or
  mesh visualization claims. The editor works only on an in-memory semantic
  draft. Save reloads the expected head under the package lock, copies all
  regular parent assets/evidence, and appends one immutable `.edit`; Cancel
  writes nothing and a stale head remains visible as a conflict;
- a Phase-5 head-revision-only export flow. Under the package lock the store
  validates and deep-copies only the current head into a fresh external
  workspace, then releases the lock before UIKit derives a semantic top-down
  PNG and one-page PDF. The Foundation-only ZIP32 STORE writer uses fixed
  metadata, bounded streaming CRC-32/SHA-256 preflight and second-pass checks,
  static outbound entry names, and an inspectable manifest. It never copies
  project history, package ownership/pending records, or package URLs into the
  share layer. Metadata, photos, and evidence JSON are rewritten to those
  outbound names and a scoped source map records project-versus-revision
  provenance so exported asset references remain resolvable. Native USDZ is
  included byte-for-byte only when validated evidence declares it present;
  fixture omissions and GLB/OBJ/PLY skips are explicit manifest statuses. The
  app keeps a marker-proven direct export lease through UIKit share completion,
  and only marker-valid direct orphan leases are recovered on a later launch;
- a Phase-6 optional private backup flow. It materializes a separate,
  full-project immutable snapshot—manifest, metadata, all revisions, owned
  regular assets, and required revision ownership records—into a deterministic
  ZIP32 STORE envelope. It has a strict app-owned archive-path map and manifest
  closure, and recovery validates into an isolated marker-owned stage before
  exact restore, no-op, divergence failure, or an explicit recover-as-copy
  rewrite. The SwiftData index stays local (`groupContainer: .none`,
  `cloudKitDatabase: .none`). An exact operator-supplied container build
  setting is required; there is no default container, active entitlement, team,
  background upload, or automatic recovery. The private-zone/CKAsset adapter,
  bounded retry/cancellation, and settings UI are source-authored only;
- authoring-time XCTest/XCUITest contracts and a static host verifier.

The app deployment floor is iOS/iPadOS 17.0. The complete hosted Xcode 16.4
build and Simulator matrix passes at that deployment target; physical RoomPlan
behavior still requires supported LiDAR hardware. `RoomScanCore` also declares
macOS 13 because it is Foundation-only and its portable test suite runs there.

## Storage model

Room file packages are authoritative. SwiftData records contain only compact
summary/search fields and are rebuilt from a successful package listing. The
store uses a hidden sibling stage for an initial package, validates all package
documents and declared assets, then promotes it as one unit. For an append, it
writes a durable pending ownership marker before promoting a new immutable
revision and updates `manifest.json` last. Recovery only reconciles
marker-owned work; it does not delete arbitrary unreferenced directories.

The store deliberately serializes writers only among `LocalRoomProjectStore`
instances in the same process. Cross-process or app-extension writers are not
implemented. Original revisions are never modified. A duplicate is a new,
single-revision head snapshot that stages and preserves the source head's
photos, declared evidence, and project thumbnail; it does not copy prior
history or derived exports. Restore copies every owned regular revision
evidence file except regenerated canonical JSON documents.

An optimistic Phase-4 edit follows the same append transaction: it reloads the
project under the same-process root lock, requires the exact expected head, and
copies every noncanonical regular parent asset (photos, declared evidence, and
future attachments) into one new immutable `.edit`. A stale expected head or a
transaction fault leaves history and parent bytes untouched.

Phase-5 materialization is an external, owned handoff workspace rather than a
copy of the package. It rejects destinations inside `Projects`, existing/link/
special destinations, stale heads, and unsafe source assets. It copies the
head's canonical semantic/annotation/measurement documents plus rewritten
metadata/revision/photos documents, project thumbnail, referenced photos,
declared evidence, and validated `attachments/` files. The package manifest and
all prior revisions stay out of the export. Source assets are streamed into the
workspace without hard links and checked against per-file, entry-count, and
aggregate caps before ZIP work begins. A historical plan-less-evidence package
is never represented as complete evidence: it either carries an explicit skip
or fails when an undeclared `evidence/` directory would make the handoff
ambiguous.

The archive is a classic ZIP32 STORE profile: UTF-8 entry names, fixed
1980-01-01 DOS timestamp, no compression, extras, comments, data descriptors,
encryption, directory entries, or ZIP64. Entry names are app-owned ASCII names;
they cannot derive directly from package paths. Its manifest lists every
non-manifest entry exactly once with media type, byte count, and lowercase
SHA-256 under `integrityScope=allEntriesExceptManifest`; neither the manifest
nor final ZIP self-hashes. The external receipt reports project/head IDs and
archive/manifest digests. UIKit-only PNG/PDF rendering is a compile/device gate;
the semantic floor plan is a bounded normalized-box depiction, not a surveyed
floor plan or captured mesh. The final archive permits at most 4096 entries,
including two required derived files and its app-owned manifest; materialization
reserves all three slots and permits at most 4093 source entries. The complete
outbound-path and ZIP profile is documented in
[Docs/export-format.md](Docs/export-format.md).

V1-A rescan acceptance recomputes the deterministic proposal under that same
store lock against the current head before appending. It copies only validated
referenced photo assets into the child and records a v2 deterministic-fixture
evidence plan whose six Apple artifact entries are explicit unavailable
omissions—there is no evidence directory and no fake USDZ. A fixture proposal
is not a production registration proof; real master rescan acceptance remains
blocked pending continuous-session or recorded-ARWorldMap proof on LiDAR
hardware. Candidate-only replacement (B) and v3/multi-segment work (C) are
deferred.

An optional per-revision evidence plan distinguishes present files from
unavailable/not-requested artifacts. A RoomPlan plan requires the raw
`CapturedRoomData` JSON, processed `CapturedRoom` JSON, and native USDZ paths;
each present file has an exact byte count and streamed SHA-256 digest, and the
revision's `evidence/` directory must contain only those declared paths. Raw
mesh, world map, and extra provenance remain explicit optional omissions until
physical-device proof exists. Apple documents `CapturedRoomData`
[`encode(to:)`](https://developer.apple.com/documentation/roomplan/capturedroomdata/encode(to:))
and [`init(from:)`](https://developer.apple.com/documentation/roomplan/capturedroomdata/init(from:)),
but neither API has run in this repository.

`evidence/` is a reserved, canonical lowercase revision namespace. New public
Save/append inputs reject case aliases such as `Evidence/`, and they cannot add
anything there without a declared evidence plan. To preserve already-committed
historical v1 packages, a missing revision compatibility field is accepted only
under a v1 project manifest. Every newly written package is v2 and every public
initial/append revision writes explicit `.strict` compatibility. Only internal
restore/duplicate of a validated historical-v1 source may write the explicit
`.legacyV1Planless` copy mode. That legacy form has no declared byte-count or
digest guarantee until it is migrated; new generic revision assets use paths
such as `attachments/` instead.

The normalized semantic document now writes `objectElements` and accepts the
legacy `movableElements` key when decoding. Optional app-owned capture-attempt
and coordinate-space epoch IDs are validated together for RoomPlan evidence;
they are provenance, not stable RoomPlan identifiers or a measurement-accuracy
claim. A RoomPlan-evidence revision requires every semantic element to declare
either a RoomPlan or coordinate-bound manual origin plus matching nonempty
provenance; fixture and legacy origins remain valid only outside that evidence
mode. The reducer mirrors the documented RoomPlan instruction/capture-error
and ARKit tracking categories without importing those frameworks into Core; a
capture-termination callback changes state only while capture is starting,
scanning, or stopping, so a late same-token callback after review is ignored.

## Mock fixture

`RoomScanStudio/Fixtures/MockRoom-v1` is embedded in the app and unit-test
targets. It has stable IDs/timestamps, seven JSON documents, a generated PNG
thumbnail, transforms/polygons, an anchored annotation and measurement, and a
photo pose marker. The loader copies the deterministic bundled PNG both as the
declared project thumbnail and as a revision-local reference-photo asset only
after explicit Save; it is never a live-camera claim. The library reads
validated bytes rather than exposing package URLs. The fixture models structural
and object elements (while accepting legacy movable-element JSON) and always
carries a non-survey-grade accuracy disclaimer.

## Host-static verification

From the repository root, run:

    python Scripts/verify_xcode_scaffold.py

The verifier parses the Xcode project/scheme/plists/privacy manifest, local
package wiring, source/resource membership, all seven fixture documents and
the PNG signature/resource membership, and the deterministic rescan sidecar,
portable imports, accessibility/test contracts, and the absence of signing,
iCloud, absolute package paths, or generated Python caches. It also runs
memory-only negative controls for duplicate XCTest declarations, broken package
wiring, and a removed evidence contract. It also checks deterministic and
production-capture source/PBX wiring, the RoomPlan-only capability split, the
one injected-session/delegate/evidence/photo contracts, and banned second-camera
or AR-session control paths. It checks that RoomScanCore remains free of Apple
UI/capture imports; this is structural evidence, not an SDK build.
For V1-A it additionally checks the locked fixture-only acceptance wiring,
production-unavailable gate, exact sidecar/PBX membership, rescan selectors,
and in-memory negative controls that remove unproven-registration rejection or
weaken the production gate.
For Phase 4 it additionally checks Core-only viewer/editor models, optimistic
expected-head edits and parent-asset carry-forward, spatial fixture data, PBX
memberships, UI selectors, a cached `nonAR` viewer with no AR/camera source
path, and in-memory mutations that remove the expected-head guard, asset
carry-forward, or non-AR camera mode.
For Phase 5 it additionally checks the Core-only export/CRC/ZIP/projection
sources, app/test PBX membership, head-only/stale-head materialization,
outbound JSON-reference rewriting and scoped source maps, ZIP second-pass and
no-overwrite contracts, marker-proven direct lease cleanup/recovery, UIKit
share-bridge wiring, and mutation controls that remove those guards. This is
still source-contract evidence, not a produced ZIP or a share-sheet run.

On the current Windows host, a pass is static structure evidence only. It
verifies source wiring for both the deterministic path and the compile-intended
Apple adapter, not their compilation or runtime behavior. There is no Xcode,
Apple SDK, Swift toolchain, Simulator, or physical LiDAR device, so it does not
prove compilation, app launch, XCTest/XCUITest behavior, RoomPlan/ARKit
behavior, CloudKit behavior, or export artifacts.

For Phase 6 it additionally checks the CloudKit-free Core backup/recovery
boundary, full-history ownership/asset closure, canonical manifest and strict
ZIP extraction contracts, app/test PBX wiring, explicit local consent,
operator-only container resolution, no `CKContainer.default()`, marker-owned
backup leases, bounded listing with malformed-descriptor isolation, and
CloudKit isolation to the one transport file. These are static checks, not a
CloudKit development-container result.

## macOS CI evidence and remaining proof

Hosted macOS CI [run 31359458769](https://github.com/PhilipN27/room-scanner/actions/runs/31359458769)
passed on commit `aa18d6bbedfc4525208653a330dfe216636f5b01`. Xcode 16.4
resolved the local package, all 122 `RoomScanCore` tests passed, the unsigned
generic iOS application built, and dynamically selected iPhone and iPad
Simulators each passed 62 app tests plus 25 UI tests. To reproduce the proved
build path on a Mac with an iOS 17-or-later SDK, run:

    xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj -scheme RoomScanStudio
    swift test

Use `xcrun simctl list devices available -j` to choose currently installed
iPhone and iPad destinations, or let `Scripts/select_simulators.py` write CI
outputs. The repository intentionally does not hardcode a simulator model or
runtime.

Follow the passing Simulator suite with physical LiDAR iPhone and iPad checks
for runtime capability gating, actual capture,
permissions, black scanning UI feasibility, raw mesh gating, and save/discard.
Production rescan is intentionally unavailable; verify that hard gate on the
device and use the explicit deterministic-fixture launch mode only for the
fixture rescan flow. The isolated `ARSession.captureHighResolutionFrame()` and
RealityKit viewer APIs compile in the hosted Xcode 16.4 build; their camera,
rendering, Save/Cancel, and stale-conflict behavior still needs physical-device
observation before release.
Run the authored export tests, inspect a generated archive with Apple
Files/Archive Utility and a separate ZIP reader, verify manifest closure/
digests and native USDZ byte identity when present, render the PNG/PDF, and
exercise iPhone/iPad share completion/cancellation and marker-lease recovery.
The build commands above have run in hosted macOS CI; the physical-device,
CloudKit, export-consumer, and system-share checks have not.

## Data and privacy posture

Local use remains offline and independent of iCloud. There is no server,
login, analytics, active entitlement, default cloud action, or automatic cloud
upload. Phase 6 exposes a local opt-in preference (default false) and separate
Check, List, Back up, and Recover actions; toggling it does not contact
CloudKit. Camera and when-in-use location descriptions are explicit, while
manual location remains usable if location access is denied. Measurements are
estimates and are never presented as survey-grade evidence.

The Home **Settings and privacy** route displays an in-app Privacy Policy link
only when the release operator supplies a valid absolute HTTPS
`ROOMSCANSTUDIO_PRIVACY_POLICY_URL` build setting. Blank, unresolved,
credential-bearing, fragmented, or malformed values remain a truthful
“not configured for this build” state. The repository never invents a policy
URL; distribution remains blocked until the Account Holder records the policy
URL and App Store privacy decision.

Read [Docs/feasibility.md](Docs/feasibility.md) before adding capture code and
[Docs/architecture.md](Docs/architecture.md) before changing local storage,
CloudKit, or exports. Do not broaden the scope without revising the
proof gates.

## Phase 7 release evidence

**Verified on Windows:** the host oracle parses release build settings,
Info/Privacy manifests, the exact 1024x1024 opaque RGB AppIcon header, semantic
palette contrast literals, adaptive-action source contracts, dynamic-type UI
test source, and the pinned CI workflow/selector self-test. This is static
evidence only.

**Verified on macOS CI:** package resolution, all 122 `RoomScanCore` tests, the
unsigned generic iOS build, and 62 app tests plus 25 UI tests on each dynamically
selected iPhone and iPad Simulator. See
[run 31359458769](https://github.com/PhilipN27/room-scanner/actions/runs/31359458769).
**Pending external evidence:** real-device capture/permission behavior,
CloudKit development-container backup/recovery, signing/archive validation,
native export inspection, PNG/PDF rendering, and system share handoff.

Release operating material lives in [Docs/setup.md](Docs/setup.md),
[Docs/real-device-test-plan.md](Docs/real-device-test-plan.md),
[Docs/privacy.md](Docs/privacy.md), [Docs/storage-performance.md](Docs/storage-performance.md),
[Docs/known-limitations.md](Docs/known-limitations.md),
[Docs/release-checklist.md](Docs/release-checklist.md), and
[Docs/dependencies.md](Docs/dependencies.md).
