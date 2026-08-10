# RoomScanStudio feasibility checkpoint

Status: Phase-2A Core, Phase-2B deterministic/production capture, Phase-3
V1-A fixture-only rescan, Phase-4 saved-room viewer/editor, Phase-5
head-revision export, and Phase-6 optional full-project backup/recovery source
are host-statically checked. The complete hosted Xcode 16.4 build and
iPhone/iPad Simulator matrix passed on 2026-08-10. This document remains a
design decision record; Simulator evidence is not physical-device validation.

## Decision summary

| Topic | Decision | Status |
| --- | --- | --- |
| Deployment floor | Use iOS and iPadOS 17.0 because SwiftData is the limiting framework. | Hosted Xcode 16.4 build and Simulator matrix passed; physical-device behavior remains unverified |
| Devices | Support iPhone and iPad. RoomCaptureSession.isSupported alone gates live capture; ARWorldTrackingConfiguration scene reconstruction support gates only optional raw-mesh evidence. Never use a device-model allowlist. | API and hardware behavior unverified |
| Capture ownership | The iOS adapter source creates one app-owned ARSession per driver and passes it to RoomCaptureSession(arSession:). It neither runs/delegates the ARSession nor creates a competing camera session; final cleanup retains ownership until RoomPlan reports didEndWith or exposes a retryable timeout. | Source-authored; SDK/API behavior unverified |
| Capture UI | A deterministic black semantic Canvas, explicit reducer route, and compile-intended live RoomPlan adapter are source-authored. A custom live presentation remains a physical-device gate/hypothesis. | Host-static only; device behavior unverified |
| Mesh preservation | Probe raw mesh collection only when RoomPlan preserves the requested sceneReconstruction configuration. Disable raw mesh capture if it does not. | Unverified |
| Required preservation | Preserve Encodable CapturedRoomData, CapturedRoom, an app-normalized semantic snapshot, native USD/USDZ, optional raw mesh/world map, photos, and provenance when each is available. | API/asset availability unverified |
| Project persistence | The app-owned project package is append-only and authoritative. SwiftData is a rebuildable explicitly local index. Initial packages and new revisions stage/validate before promotion; append updates the package head last. Phase 2A adds revision-local evidence manifests and an explicit capture commit boundary. | Source-authored; host-static structure checked |
| Rescans | Production accepts only a continuous session or successful ARWorldMap relocalization. V1-A is fixture-only: a typed sidecar exact-bijection proposal can be accepted under the store lock only with an explicit test launch argument; production is hard-unavailable. | Host-static fixture wiring; real registration unverified |
| Rendering/editing | RealityKit entities are disposable render projections. Edit copy-on-write semantic drafts; ceiling data is manual or derived, never represented as native RoomPlan evidence. | Architecture selected |
| Cloud | Keep SwiftData local. Phase 6 adds only explicit opt-in private immutable snapshot backup/recovery using one CKAsset; no launch/toggle call, background sync, subscriptions, or source-of-truth migration. Local use never depends on iCloud. | Source-authored; CloudKit behavior unverified |
| Export | Phase 5 exports only the validated current head, never a package backup or revision history. Native USDZ is included byte-for-byte only when declared-present evidence validates. GLB/OBJ/PLY are explicit skips without a vetted converter. | Source-authored; artifact quality unverified |
| ZIP | Phase 5 uses a Foundation-only deterministic classic ZIP32 STORE profile with a separately inspectable manifest; no ZIP dependency is added. | Source-authored; external consumer inspection unverified |

## Host inspection

Inspection was performed on 2026-08-08 from the Windows workspace. The
following executable lookup returned absent for xcodebuild, xcrun, swift, and
swiftc. There is no Apple SDK, Xcode, Simulator, or physical device available
on this host. WSL is not available for an alternate Apple build path.

Therefore this phase can establish only source, fixture, plist, JSON, XML,
package-reference, and project-reference structure. It cannot establish that
the project builds, that the referenced framework symbols compile, that a
simulator launches, or that LiDAR capture works on either iPhone or iPad.

The repository had no source/build baseline, and StarterFolder was empty at
inspection. The root project had no repository-local AGENTS.md instruction file.

## Capability and capture feasibility

RoomPlan support must be checked before capture through
RoomCaptureSession.isSupported. AR mesh support is separately checked through
the world-tracking configuration rather than a hardware-name check, and gates
only optional raw-mesh evidence—not RoomPlan capture itself. The Phase-0 app
exposes this as an injectable capability provider so that Simulator and
RoomPlan-unsupported states can show a fixture-mode explanation instead of
crashing. A RoomPlan-capable device without mesh support remains capture-capable
with raw-mesh evidence disabled.

The planned scanning flow owns exactly one ARSession. If the SDK supports the
expected RoomCaptureSession initializer, RoomCaptureSession receives that
session. Camera, RoomPlan, and mesh work must not independently create
competing capture sessions. A black capture UI is not treated as guaranteed:
the physical-device gate must prove whether a custom presentation can coexist
with the RoomPlan session.

Raw mesh and world-map assets are optional provenance artifacts. V1 does not
collect raw mesh even when the optional capability is present. Scene
reconstruction is enabled/probed only if it remains configured after RoomPlan
session setup. If it is not preserved, raw mesh collection is turned off rather
than presenting mixed-coordinate or unsupported data as reliable.

## Storage, revisions, and rescan feasibility

The project package, not a database row, is the source of truth. It contains
the immutable original and every later revision. The Phase-1 store writes an
initial Save as a complete hidden sibling package and promotes it only after
validation. It appends later revisions through a staged directory plus a
durable ownership marker, updates the package head last, and reconciles only
marker-owned interrupted work. Load validation requires an initial/duplicate
root with no parent or restore source; later revisions cannot be initial or
duplicate, and a revert must reference an earlier revision. Original revision
files never mutate. The current writer lock is explicitly same-process only;
cross-process or app-extension writes remain out of scope.

Phase 2A stores optional immutable evidence only on a revision manifest, not
on the project policy. A RoomPlan evidence plan requires contained, regular,
byte-count- and streamed-SHA-256-matched raw `CapturedRoomData` JSON, processed
`CapturedRoom` JSON, and native USDZ files. The revision `evidence/` directory
is exact and closed over the plan: every regular file is declared once, aliases
and undeclared files fail closed. New public writes require the canonical
lowercase `evidence/` namespace and a plan, rejecting case aliases such as
`Evidence/`. A legacy pre-Phase-2 package may carry an already-committed
canonical plan-less evidence directory only when its project manifest is
historical v1 and its revision omits the compatibility field. New packages are
v2; public initial/append revisions encode strict compatibility. Internal
duplicate/restore may encode a legacy-v1 copy mode only after loading that
valid v1 source and performing link-free regular-file validation; its files
have no digest/byte-count guarantee until migration. It records raw mesh,
world map, and provenance as explicit unavailable/not-requested omissions until
physical proof exists. A deterministic fixture may record only explicit fixture
omissions and never a fake native USDZ path. Every present file is checked again
on load. Duplicate and restore stage/copy the source-head photos, declared
evidence, and thumbnail bytes into a new immutable snapshot; duplicate does not
copy prior history or derived exports.

Apple documents both `CapturedRoomData.encode(to:)` and
`CapturedRoomData.init(from:)`, so preserving raw encoded data is an intended
adapter path. The iOS adapter source calls the supported encoder path into
attempt scratch before explicit review, but this repository has not executed
that source against Apple frameworks. The Core layer remains Foundation-only.
Raw mesh and world map remain optional physical LiDAR/SDK gates, not success
claims.

The Foundation-only capture reducer carries an attempt token through every
event/effect. It mirrors the documented RoomPlan coaching and capture-error
categories plus ARKit tracking state/reason as qualitative operational signals,
never as accuracy values. A RoomPlan-evidence revision requires every semantic
element to identify a `roomPlan` or coordinate-bound `manual` origin and carry
matching nonempty provenance; fixture and legacy origins decode only outside
that evidence mode. GPS authorization is tokenized. Reference photos are
requested only while the app-owned session is scanning; one request may be in
flight, Stop waits for its success/failure callback, and a stale callback is
ignored. Capture termination is accepted only in starting, scanning, or
stopping, so a late same-token callback after review has no state effect.
Before explicit Save is accepted, Discard invalidates the token,
terminates a live capture or cancels processing where applicable, asks for
scratch cleanup, and emits no store-save effect.
Live termination while GPS is pending also emits attempt-scoped location
cancellation; queued camera/start/GPS/process/photo effects check cancellation
and active attempt/phase before entering their dependencies. A stale cached
one-shot GPS fix resolves as a nonfatal no-fix result rather than leaving Save
blocked by a leaked continuation.
`commitInitialCapture(..., decision: .discard)` returns before ID generation,
root creation, or asset reads; `.save` is the only path that stages a package.
The `.saving` phase is intentionally non-cancelable because a persistence
effect may already be promoting a package; the UI must hide or disable Discard
then. A save failure returns to review, where Discard is available again.

The deterministic Phase-2B coordinator now freezes the processed semantic
snapshot as review truth and ignores later same-token live snapshots after
review. Before scratch removal, it cancels and awaits its tracked start/photo/
processing tasks and an adapter-provided writer barrier. A cleanup error leaves
the attempt in its cleanup phase with an explicit retry action instead of
routing away. Scratch uses a dedicated sibling root: configured roots and
attempt leaves reject symbolic links, and startup recovery may remove only
validated direct owned attempt directories. A V1 single-scene coordinator lease
prevents a SwiftUI re-render from constructing a second deterministic driver.
Navigation back and interactive dismissal are blocked after an attempt begins;
the user exits through Close/Discard only after terminal cleanup. GPS is still
optional, but Save is disabled while its tokenized request is in flight so a
late fix cannot race into persisted review metadata. These are source-authored
deterministic contracts only; scratch filesystem behavior and UI routing still
need macOS/Simulator proof.

SwiftData is a small local search/index layer that can be reconstructed from
package summaries. Its `ModelConfiguration` explicitly sets
`groupContainer: .none` and `cloudKitDatabase: .none`; it never owns scan data
or large assets. A failed index rebuild must leave package data visible rather
than replacing it with an empty library.

The store rejects unsafe identifiers, traversal paths, configured-root leaf
links, package/revision/document/asset links, dangling declared assets, and
duplicate semantic/annotation/measurement/photo IDs. A corrupt sibling package
is exposed as a listing diagnostic while valid sibling packages remain usable.

“A rescan candidate is valid only if one of these registrations is proven: 1. continuous capture in the original app-owned ARSession, or 2. successful relocalization against a recorded ARWorldMap.”

RoomPlan identifiers are not assumed stable across sessions, and confidence is
not treated as geometric accuracy. V1 stops the app-owned session with
`pauseARSession: true` and does not record an ARWorldMap, so production master
rescan acceptance is deliberately unavailable and does no camera/AR work. The
only implemented V1-A path is a typed deterministic sidecar enabled explicitly
by `--use-deterministic-rescan-fixture`. It requires a complete exact bijection
of base and candidate semantic elements, with matching layer/kind and valid
candidate geometry/provenance. Candidate transforms must be finite usable
affine matrices (approximately `[0, 0, 0, 1]` homogeneous row and a
non-singular 3x3 basis); this does not narrow legacy package decoding.
Additions, deletions, duplicate mappings,
wrong fixture/frame/proof, and tampering fail closed. It preserves durable base
IDs while taking geometry/provenance from the candidate, preserves annotations,
measurements, and photo assets, and labels measurements unchanged and
unrevalidated. Accept recomputes under the store lock and appends one immutable
`.rescan` revision with deterministic-fixture evidence omissions; Undo is
transient, while Revert appends a new immutable child. No arbitrary vertex
fusion or same-room merge claim is made. Candidate-only replacement graduation
(B) and v3/multi-segment work (C) remain deferred until physical LiDAR
registration proof exists.

## Phase-4 saved-room viewer and editor feasibility

The Phase-4 viewer is bounded to saved, normalized semantics. It is not an AR
viewer and does not expose a live camera, raw mesh, native USDZ rendering, or
survey visualization. Source is authored to use a fully virtual RealityKit
`ARView` with `.nonAR`, disabled automatic session configuration, and an
explicit perspective camera. Structural/object boxes, measurements, annotations,
and photo pose markers are disposable render projections with independent
visibility roots. The source contains no AR-session run/configuration or camera
permission path. This is host-static evidence only: exact RealityKit signatures,
render behavior, gesture interaction, and iPhone/iPad layout remain macOS/Xcode
and Simulator/device proof gates.

The editor is deliberately an optimistic semantic editor, not a native RoomPlan
or mesh authoring tool. It works on a value draft and has no package URL. Its
only persistence path reloads the expected head under the same-process package
lock and appends a new immutable `.edit` after carrying parent regular assets
and evidence forward. Cancel writes nothing; a stale head or injected fault
writes no child and leaves the parent byte-for-byte unchanged. Spatial notes,
measurements, and manual objects are additive semantic data with finite/anchor/
layer validation. Manual provenance is explicit. A non-pose label or dimension
edit preserves a captured transform's pitch/roll/scale; yaw is an explicit
adjustment. XCTest contracts are authored but unexecuted on this Windows host.

MockRoom-v1 now supplies the minimum deterministic spatial data needed to
exercise the path: transforms, structural polygons, an anchored annotation,
paired measurement endpoints, and a camera-pose photo marker. The bundled PNG
is copied to the photo path only as deterministic fixture data after Save. It
is not reference-photo or capture evidence from an Apple device.

## Phase-5 export feasibility

Phase 5 is a bounded head-revision handoff, not a backup or a history export.
The store materializes only the current validated head into a fresh external
workspace under its same-process package lock, then releases the lock before
derived work. It includes the six canonical head documents, the referenced
thumbnail/photos, declared present evidence, and validated attachments; it
excludes the project manifest, prior revisions, pending/ownership records,
package exports, and unreferenced files. Asset references in exported
`metadata.json`, `revision.json`, and `photos.json` are rewritten to static
outbound names, and `source-map.json` distinguishes project-root from
revision-root source references so no exported JSON points to a missing entry.

The ZIP implementation is Foundation-only classic ZIP32 STORE: fixed
timestamps/attributes, UTF-8 flag, no compression, extras, comments,
directories, descriptors, encryption, or ZIP64. It preflights bounded-stream
CRC-32/SHA-256/size values, validates a second source pass, and writes an
inspectable manifest over all non-manifest entries. Native USDZ is copied only
when the validated evidence plan says it is present; deterministic-fixture
omissions and GLB/OBJ/PLY are stable skipped statuses. UIKit is limited to a
bounded semantic top-down PNG, a one-page PDF summary, and a scoped system
share bridge. These are source contracts only: ZIP readers, Files/Archive
Utility, PDF/PNG rendering, native USDZ, and share lifecycle all remain macOS/
device proof gates. The detailed profile is in [export-format.md](export-format.md).

## Phase-6 backup/recovery feasibility

Phase 6 is a distinct full-project backup, not an extension of the Phase-5
head export. The Core package remains Foundation-only and produces a bounded,
deterministic ZIP32 STORE archive containing the package manifest, metadata,
all immutable revisions, their required v2 ownership records, and validated
owned regular assets. Archive paths are app-owned indexed ASCII names; the
canonical backup manifest maps them back to separately validated package paths.
This avoids rejecting a valid Unicode package path merely because ZIP names are
strict ASCII.

Recovery verifies the archive and manifest closure before staging any package.
An exact missing project can be atomically restored; an identical snapshot is a
no-op; divergence fails closed unless the user explicitly selects a recovered
copy. That copy rewrites every project-ID-bearing package document and revision
ownership record while preserving revision lineage and asset bytes. There is no
edit revision or full-history mutation.

CloudKit is optional and isolated in one app transport. The local preference
defaults false and causes no CloudKit call when toggled. Missing, blank, or
unresolved operator configuration is Not configured, never
`CKContainer.default()`. A single private-zone record and CKAsset is bounded
locally to 512 MiB, but Apple does not publish a current firm CKAsset upload
cap; a development-container upload/recovery test is therefore an external
gate. Listing retains valid descriptor records when another successfully
fetched descriptor fails local validation, but counts and discloses only a
bounded number of skipped malformed records; no skipped record is recoverable.
Per-record CloudKit failures still fail the explicit List operation. See
[icloud-setup.md](icloud-setup.md).

## Phase-1 library feasibility

The Phase-1 UI is intentionally limited to package-backed profiles and
revisions: active/archived listing, metadata edit, duplication,
archive/unarchive, confirmed permanent delete, revision inspection, and
restore as a new immutable revert revision. Restore copies every owned regular
non-symlink revision evidence file except the canonical JSON documents that it
regenerates, preserving future native/mesh/world-map evidence rather than
silently omitting it.

MockRoom-v1 provides a seven-document, deterministic review input plus a
generated PNG thumbnail. It is never seeded on ordinary launch. Its explicit
Save creates one package and copies the declared project-scoped thumbnail;
explicit Discard creates none. The UI requests only validated thumbnail bytes
from the store, never a package filesystem URL. This is file-store/UI wiring
only; it is not a RoomPlan capture claim.

## Reference and license review

No third-party source is copied into this repository.

| Reference | Review outcome | Decision |
| --- | --- | --- |
| https://github.com/BaidetskyiYurii/RoomPlanDemo | The public main branch has no visible LICENSE in the reviewed reference. | Do not copy code; use only as a conceptual reference. |
| https://openplan3d.com/capture | OpenPlan3D is MIT, but its web/Svelte and pre-release capture orientation conflicts with this native, offline-first scope. | Do not copy code or adopt its capture stack. |

The new repository itself had no prior license, source baseline, or build
baseline. Phase 0 adds an MIT license for new work; that does not retroactively
license external reference material.

## Rejected alternatives

- A device-name compatibility table: it would become stale and contradicts
  runtime framework capability checks.
- Multiple AR/camera sessions: competing ownership would make tracking and
  capture provenance unreliable.
- Direct mutation of a current revision: it would violate original-scan
  preservation and make undo/revert ambiguous.
- Automatic or vertex-level same-room fusion: no verified RoomPlan API or
  registration proof supports that safety claim.
- SwiftData as the sole asset store: large meshes, photos, and native exports
  need file-backed lifecycle and independent backup handling.
- Default-on CloudKit: it violates local-first, offline use.
- A full-package/history backup presented as an export: it would misrepresent
  immutable lineage and expose unrelated package records.
- An unbounded or converter-backed GLB/OBJ/PLY export: each needs a vetted
  converter and artifact inspection.

## Evidence tiers and proof gates

| Tier | Required evidence | Current state |
| --- | --- | --- |
| Host static | Parse Xcode metadata, plist, JSON, XML, eight fixture documents plus PNG signature and the RescanFixture sidecar, local-package/PBX wiring, source/resource memberships, Phase-2 through Phase-6 contracts, and security settings. | Passed on 2026-08-09; static only |
| macOS Xcode | Clean Xcode build, unit tests, and Simulator test run against the selected SDK. | Passed in hosted run 31359458769: package resolution, 122/122 Core tests, unsigned generic iOS build, and 62 app plus 25 UI tests on each selected iPhone/iPad Simulator |
| Physical LiDAR iPhone and iPad | Capability gates, permission paths, capture, tracking loss, save/discard, and verification that production rescan remains unavailable on both classes. | Not available |
| CloudKit development container | Explicit opt-in behavior, private snapshot/CKAsset persistence, cancellation lookup, recovery, and local-only regression check. | Phase-6 source/static contracts only; not performed |
| Export inspection | Inspect a produced ZIP with independent readers, verify manifest closure/digests, source-package immutability, native USDZ identity when present, PNG/PDF rendering, and share completion/cancel cleanup. | Phase-5 source/static contracts only; not performed |

## Unknowns that require later proof

1. Physical-device behavior of the RoomPlan/ARKit calls that compile in the
   hosted Xcode 16.4 build.
2. Whether RoomPlan preserves scene reconstruction on the app-owned ARSession.
3. Whether an app-owned session and a custom black scan surface work together.
4. CapturedRoomData persistence, CapturedRoom export metadata, world-map
   storage, and their practical file sizes on current SDKs.
5. Registration/relocalization reliability between revisions on real LiDAR
   iPhone and iPad hardware.
6. ModelIO output fidelity and legal/technical converter choices for optional
   formats.
7. CloudKit asset size, failure recovery, and opt-in UX.
8. ZIP compatibility with Apple Files/Archive Utility and independent readers,
   UIKit PNG/PDF rendering bounds, native USDZ inclusion, and share/lease
   cleanup on iPhone and iPad.

## Official API references

- RoomCaptureSession: https://developer.apple.com/documentation/roomplan/roomcapturesession
- RoomCaptureSession support: https://developer.apple.com/documentation/roomplan/roomcapturesession/issupported
- RoomCaptureSession coaching instruction: https://developer.apple.com/documentation/roomplan/roomcapturesession/instruction
- RoomCaptureSession capture error: https://developer.apple.com/documentation/roomplan/roomcapturesession/captureerror
- CapturedRoomData encoding: https://developer.apple.com/documentation/roomplan/capturedroomdata/encode(to:)
- CapturedRoomData decoding: https://developer.apple.com/documentation/roomplan/capturedroomdata/init(from:)
- CapturedRoom: https://developer.apple.com/documentation/roomplan/capturedroom
- CapturedRoom export: https://developer.apple.com/documentation/roomplan/capturedroom/export(to:metadataurl:modelprovider:exportoptions:)
- RoomBuilder processing: https://developer.apple.com/documentation/roomplan/roombuilder/capturedroom(from:)
- AR high-resolution frame capture: https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe()
- One-structure scanning guidance: https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- ARKit scene reconstruction: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- ARCamera tracking state: https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
- ARCamera limited-tracking reason: https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum/reason
- ARWorldMap save/load guidance: https://developer.apple.com/documentation/arkit/saving-and-loading-world-data
- SwiftData and device sync: https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
- CloudKit CKAsset: https://developer.apple.com/documentation/cloudkit/ckasset
- CloudKit bulk record lookup: https://developer.apple.com/documentation/cloudkit/ckdatabase/records(for:desiredkeys:)
- CloudKit bounded-zone query: https://developer.apple.com/documentation/cloudkit/ckdatabase/records(matching:inzonewith:desiredkeys:resultslimit:)
- CloudKit atomic record modification: https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:)
- CloudKit custom zones: https://developer.apple.com/documentation/cloudkit/ckrecordzone
- ModelIO export support: https://developer.apple.com/documentation/modelio/mdlasset/canexportfileextension(_:)

## Phase 7 release feasibility checkpoint

**Verified on Windows:** the structural oracle parses release substitutions,
the privacy manifest, icon PNG IHDR/color type, literal semantic contrast
pairs, Dynamic Type test source, and the full-SHA-pinned CI workflow plus its
synthetic simulator-selector policy. These checks do not compile or render the
app.

**Verified on macOS CI:** Xcode package resolution, 122/122 portable tests,
unsigned generic iOS build, and 62 app plus 25 UI tests on each dynamically
selected iPhone and iPad Simulator passed in run 31359458769. **Pending
external evidence:** release archive/signing, Accessibility Inspector/VoiceOver
review, physical capture/permissions, CloudKit private backup/recovery, export
artifact inspection, and system-share completion.

The privacy manifest remains tracking false with no tracking domains or
declared collected data. It records required-reason File Timestamp `C617.1` and
User Defaults `CA92.1`. App Store Connect/privacy-report validation is an
external release-owner gate. See [privacy.md](privacy.md) and
[release-checklist.md](release-checklist.md).
