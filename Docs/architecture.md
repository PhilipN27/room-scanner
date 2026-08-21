# RoomScanStudio architecture checkpoint

Status: Phase-2A Core/storage, Phase-2B deterministic/production capture,
Phase-3 V1-A fixture-only rescan, Phase-4 saved-room viewer/editor, Phase-5
head-revision export, and Phase-6 opt-in full-project backup/recovery source
are authored and host-statically checked. Slice 3 local AI Room
Package/disclosure/Concept Set paths are implemented and locally/Simulator-
verified: 266/266 Core tests; complete 219/219 schemes (185 app + 34 UI) on
both iPhone 16 Pro and iPad (10th generation) Simulators; and focused Slice 3
UI evidence of 5/5 on each form factor. On 2026-08-10 the complete hosted
Xcode 16.4 build and iPhone/iPad Simulator matrix passed. Physical RoomPlan
capture, independent ZIP/render inspection, CloudKit development-container,
signing, and physical-device proof remain separately gated. The implementation
is local-first and one-room only; Slice 3 adds no hosted/provider dependency.
Slice 4 adds an optional, default-off professional-service foundation under
`HostedService/` and a lazily constructed iOS professional boundary. Local
lane evidence exists, but whole-slice PostgreSQL/composition acceptance,
non-production provider evidence, physical Face ID evidence, and production
provisioning/release remain separately gated.

## Architectural boundaries

| Boundary | Responsibility | Phase-0 rule |
| --- | --- | --- |
| App shell | SwiftUI navigation, palette, and user-facing capability state. | Home has exactly Existing Rooms and New Room Scan as primary actions. |
| Capability boundary | Reports RoomPlan/ARKit support. | Protocol-backed so unsupported hardware and tests use a deterministic fixture-mode state. |
| Capture boundary | Owns one ARSession and mediates RoomPlan/ARKit. | No device model checks and no concurrent camera/AR sessions. |
| Project-package boundary | Stores authoritative room packages, assets, manifests, and revisions. | Append-only; staged writes; update head last; validate owned assets and reject links. |
| SwiftData boundary | Local query/index convenience. | Explicit `groupContainer: .none` and `cloudKitDatabase: .none`; rebuildable from packages; never authoritative. |
| Semantic boundary | Normalized app model for structure, movable objects, annotations, measurements, and accuracy disclaimers. | Codable snapshot is independent from opaque framework identifiers. |
| Render boundary | Converts semantic data to RealityKit entities. | Entities are disposable projections, never editable truth. |
| Revision/rescan boundary | Builds reviewable semantic proposals and lineage. | Continuous session or successful ARWorldMap relocalization only; fail closed otherwise. |
| Cloud backup boundary | Explicit private immutable backup/recovery only. | Local opt-in defaults false; no launch/toggle call, no default container, sync, or source-of-truth migration. |
| Export boundary | Generates native and verified optional deliverables. | USD/USDZ required; manifest reports generated/skipped/failed formats. |
| AI package boundary | Plans and builds one source-bound provider-neutral archive after exact disclosure review. | Offline; complete ledger/closure; source immutable; no provider/model client. |
| Concept boundary | Validates, sanitizes, persists, reviews, compares, archives, and deletes additive concept media. | Separate store; untrusted imports; atomic promotion; never captured truth. |
| Professional entry boundary | Lazily enters optional account/workspace behavior after an explicit user action. | Default off; guest launch constructs no hosted/auth client and makes no hosted request. |
| App-owned API boundary | Normalizes the sealed Slice 4 HTTP API, app-owned opaque sessions, authorization, flags, and provider adapters. | Clients never receive database, AWS, service-role, Cognito, or provider credentials/tokens. |
| Professional persistence boundary | Stores canonical principals, sessions, workspaces, memberships, subscription/quota state, and bounded audit state. | PostgreSQL 16; forced RLS; lane-specific non-owner/non-`BYPASSRLS` roles; server-derived tenant context. |
| Professional object boundary | Holds private, versioned server-owned tenant/quarantine objects. | S3 never authorizes; only narrow server-issued capabilities cross the client boundary. |

## Package-first room layout

The package is the durable truth and uses deterministic IDs where fixtures and
tests require them:

    RoomProject/
      manifest.json
      metadata.json
      revisions/
        revision-001/
          revision.json
          semantic-model.json
          annotations.json
          measurements.json
          photos.json
          photos/
          evidence/
            roomplan/captured-room-data.json
            roomplan/captured-room.json
            native/RoomScan.usdz
            arkit/                 optional raw mesh/world map provenance
      thumbnails/
      exports/

Attempt scratch is deliberately outside that layout:

    Application Support/RoomScanStudio/
      Projects/                 authoritative room packages
      CaptureScratch/
        attempt-<token>-<nonce>/ transient, owned review inputs only
      ExportScratch/
        .roomscan-head-export-<nonce>/
          lease-ownership.json  fixed marker; external handoff only
          head/                 frozen current-head materialization
          roomscan-head-<revision>.zip
      ConceptSets/              additive, source-bound Concept Set store
      ConceptImportScratch/     marker-owned untrusted import staging
      AIRedesignProvenance/     validated built-package bindings only

`CaptureScratch` is never an authoritative package directory. It is removed
after successful promotion or completed discard, subject to the guarded retry
and orphan-recovery rules below.

`ExportScratch` is likewise outside `Projects`, but it has a narrower lease
rule: each direct child carries a regular fixed-schema ownership marker. Cleanup
and crash recovery remove only marker-valid, non-symlink direct children; a
prefix-matching lookalike or link is preserved for manual review. Export never
recursively clears this root.

## Slice 3 local AI redesign boundary

`RoomScanCore` owns the provider-neutral artifact slots/plans, canonical
digests, package/ledger/disclosure validation, deterministic ZIP construction
and independent extraction, Concept Set/archive schemas, and atomic local
Concept store. It imports no SwiftUI, UIKit, Vision, provider, authentication,
or network API.

The iOS `Infrastructure/AIRedesign` layer reloads the exact sealed source,
requires confirmed/manual orientation and a valid nonempty intent, renders the
floor/six canonical derivatives, sanitizes selected images, runs advisory
Vision analysis, freezes bytes into an owned lease, and coordinates exact
approval. `Features/AIRedesign` presents the profile, brief/permissions,
readiness, actual selected/raw previews and metadata, warnings, GPS exclusion,
provider notice, artifact inventory, Share Sheet request, and Concept review
actions. SwiftUI never receives an authoritative project URL or mutates source
geometry.

Package review has two distinct state machines. Core disclosure coordination
uses `idle`, `reviewing`, `approved`, `rejected`, `stale`, and `consumed`; the
production screen uses `drafting`, `readyForReview`, `approved`, `stale`,
`archiveReady`, and `cleanupFailed`. Any source/profile/plan/selection change
invalidates approval. Finalization independently extracts the archive before
publishing a one-shot Share Sheet request. Completion, cancellation, error, or
dismissal cleans only that exact lease; cleanup failure remains retryable.

Concept imports never stage inside `Projects`. The bounded archive/image
boundary rejects unsafe paths, links, aliases, remote references, unsupported
media, rebound source identity, and incomplete closure, then performs a fresh
decode/re-encode before same-root promotion. Automatic mapping requires an
authenticated finalized-package binding (the exact local canonical manifest and
complete view ledger, not account authentication) plus a canonical view
identifier; otherwise mapping is manual or unmatched. Concept media/metadata
remains additive and archive/delete operates on one selected concept only.

The final local/Simulator matrix independently proved deterministic AI-ready
and Complete archive extraction/manifest/ledger closure, exact
finalized-package Concept automatic mapping, and local Share Sheet lease
cleanup. It does not prove real provider behavior or terms, physical Share
Sheet/import behavior on iPhone, or any physical-iPad behavior.

## Slice 4 optional professional-service boundary

The professional service is a control plane beside—not underneath—the local
capture/package system. Strict TypeScript on Node.js 24 provides the app-owned
service and AWS CDK v2 definitions. API Gateway HTTP API payload v2 and Lambda
form the private request boundary; Aurora PostgreSQL Serverless v2 in
`us-east-1` is the canonical identity/membership/subscription/audit store; and
private versioned S3 uses server-owned tenant prefixes. Cognito is only the
Apple/custom-auth substrate, SES is the bounded mail adapter, and Stripe enters
through a raw-body app-owned billing adapter. Provider and database types do
not enter `RoomScanCore` or the public package/resource contracts.

The sealed Slice 4 v3 route manifest has 19 operations for health,
verified-email request/candidate request/browser confirmation/app redemption,
Apple sign-in and candidate proof, session refresh/logout, Stripe ingress,
workspace bootstrap/activation and workspace/membership/subscription/quota
reads, plus deliberate identity mutation. It contains no Slice 5
synchronization/upload, Slice 6 portal or publication, or Slice 7 lifecycle
endpoint. Every protected route resolves an app-owned opaque access digest and
runs central authorization plus repository work in one database transaction.
The server derives workspace scope from the canonical principal and active
membership; no caller workspace path, internal UUID, quota period, Stripe
binding, or object key supplies authority.

The verified-email v3 handshake separates mailbox confirmation from app
credential delivery. The requesting app retains a 32-byte verifier; PostgreSQL
stores only its S256 challenge plus keyed digests. A static, no-store browser
page performs no work until a trusted submit, then confirms the one-time link
and displays an eight-character transfer code without receiving a session.
Only the app holding the completion ID, verifier, exact purpose, and displayed
code may redeem. Exact lost-response replay returns an original result only
while that session or identity receipt remains live. The design supports
cross-device confirmation without letting an attacker who merely requested a
victim's address claim a blindly clicked link.

Apple finish uses an explicit API → Cognito challenge → app-session chain. The
API validates the app-owned state/nonce/S256 attempt, exchanges the code,
generates raw app access/refresh tokens and keyed hashes, and waits for Cognito
custom-auth success. Only the auth-challenge runtime may atomically consume the
one-time Apple bridge and issue the app session. The API discards Cognito
tokens and resolves its own new access hash before returning app-owned public
identity and raw app tokens. Local concrete repositories and composition do
not substitute for the still-required non-production Cognito/Apple exercise.

Three versioned server flags fail closed: `professional_sign_in_enabled`,
`hosted_operations_enabled`, and `publication_enabled`. Guest launch never
fetches them. Rollback disables professional sign-in and hosted operations and
revokes affected sessions while preserving local packages, AI Room Package
export, Concept Sets, legacy export, and Share Sheet preparation. Publication
is reserved and remains disabled until Slice 6.

The current decisions are recorded in
[ADR 0002](decisions/0002-ai-redesign-slice-4-service-foundation.md), the
provider-neutral boundary in
[the service contract](contracts/ai-redesign-service-contracts-v1.md), and
honest completion status in
[the Slice 4 evidence ledger](evidence/2026-08-19-ai-redesign-slice-4-verification.md).

The live asset layout may add Encodable CapturedRoomData, a CapturedRoom-native
USD/USDZ export, optional raw mesh, optional ARWorldMap, photos, and provenance
only when each has been verified as available on the selected Apple SDK and
device. The normalized semantic snapshot remains readable without a proprietary
render object.

## Revision transaction

1. A user explicitly chooses Save or accepts a reviewed rescan proposal.
2. For a first Save, the complete package is written to a hidden sibling stage:
   manifest, metadata, immutable revision, and declared assets. It is validated
   before one same-root promotion to its never-existing project directory.
3. For an append, the store writes and validates a hidden new revision, writes
   a durable ownership/pending marker, promotes the revision, then writes
   `manifest.json` with its new head last.
4. Validation covers manifest IDs and parent lineage; stored revision-reason
   lineage (an initial/duplicate root with no parent/source, later edits/rescans
   with no restore source, and reverts whose source is an earlier revision);
   semantic, annotation, measurement, and photo JSON; finite/valid spatial,
   GPS, and measurement values; global semantic element IDs; mobility labels
   that do not contradict their structural/movable array; declared assets; a
   revision-local evidence manifest; and link-free contained package paths.
   Every present evidence file is regular, contained below `evidence/`, and
   byte-count and streamed SHA-256 verified before promotion and on load. The
   evidence directory is closed: no undeclared regular file or path alias is
   accepted. New writes reserve exactly lowercase `evidence/` for a declared
   plan and reject case aliases. New package manifests are v2, and every new
   public initial/append revision records explicit strict evidence
   compatibility. A missing compatibility field is accepted only for a
   historical v1 project revision. Internal duplicate/restore can record the
   explicit legacy-v1 plan-less mode only after it has loaded a valid historical
   v1 source with an already-committed canonical lowercase `evidence/` tree;
   it has no digest/byte-count guarantee until migrated and cannot be created
   through a public new-write API.
   `.movable` is rejected in the structural array and `.structural` in the
   movable array; `.fixed`, `.unknown`, and nil remain valid in either category.
5. On startup/load, recovery may only finish or roll back work proven by the
   marker and its ownership file. It never deletes an arbitrary unreferenced
   revision directory.
6. Any caught failure reconciles marker-owned work so the former head and
   original revisions remain untouched and a retry with the revision ID is
   possible.

Before an explicit Save is accepted, Discard is a deterministic terminal state
with no package mutation. The pure attempt-token reducer emits an initial
store-save effect only from review; pre-commit Discard invalidates the token
and emits scratch cleanup, never a store-save effect. `.saving` is deliberately
non-cancelable because persistence may already be promoting a package; the UI
must hide or disable Discard in that phase. A save failure returns to review,
where Discard is available again. Undo and revert create or select lineage-safe
revisions; they do not overwrite history.

## Rescan safety contract

“A rescan candidate is valid only if one of these registrations is proven: 1. continuous capture in the original `RoomCaptureView`-owned ARSession, or 2. successful relocalization against a recorded ARWorldMap.”

Phase 3 V1-A deliberately proves neither production registration path. V1 final
capture stops with `pauseARSession: true`, so continuity is unavailable, and the
app does not request or retain an ARWorldMap. Production therefore exposes only
`registrationEvidenceMissing` and creates no AR/camera work. The explicit
`--use-deterministic-rescan-fixture` path is a typed bundled proof for the
stable MockRoom head only; it is not a live registration claim.

The fixture candidate is a semantic replacement proposal, not a vertex-fusion
or same-room merge API. Its explicit matches must be an exact bijection over
every base/candidate element, preserve layer and kind, and reject additions,
deletions, duplicate mappings, invalid geometry, or tampering. Candidate poses
must be finite usable affine transforms: an approximately `[0, 0, 0, 1]`
homogeneous row and a non-singular 3x3 basis. This stricter candidate check
does not change permissive legacy transform decoding. Acceptance
preserves durable base IDs while taking geometry/provenance from the candidate;
annotations, photos, and measurements survive, with measurements visibly
unchanged and unrevalidated. The locked store reloads and recomputes before one
immutable `.rescan` append. Undo is transient and allocates nothing; Revert is
the existing new immutable child. RoomPlan IDs are not assumed to persist across
sessions, and confidence values are not claimed to provide geometric accuracy.
The later candidate-only replacement graduation (B) and v3/multi-segment work
(C) remain deferred.

## Capture and render model

`RoomCaptureSession.isSupported` alone gates whether a live RoomPlan capture
path may open. Simulator and RoomPlan-unsupported states explain the explicit
fixture path instead. ARWorldTrackingConfiguration scene-reconstruction support
is a separate optional raw-mesh evidence gate: a RoomPlan-capable device without
mesh support can still capture, but cannot claim raw-mesh evidence. A custom
black scanning surface is a testable hypothesis; it must be evaluated on
physical hardware. If RoomPlan does not preserve the requested reconstruction
setup, raw mesh collection is disabled.

The semantic editor owns copy-on-write drafts. RealityKit entities are rebuilt
from those drafts as view projections. Ceiling data is manual or derived, so it
cannot be labeled as native RoomPlan evidence. The canonical semantic JSON uses
`structuralElements` and `objectElements`; legacy `movableElements` decodes for
compatibility. A fixed or unknown object is not silently reclassified as a
structural surface, and all measurements carry a non-survey-grade accuracy
disclaimer. For a RoomPlan-evidence revision, each semantic element must state
either `roomPlan` or coordinate-bound `manual` origin and provide a nonempty,
matching capture-attempt/coordinate-epoch provenance record. Fixture and
legacy origins remain decodable but are rejected in that evidence mode.

Phase 2A supplies the pure Foundation capture reducer with categorical guidance
(coaching, low classification confidence, lighting/tracking, and another-pass
heuristics), RoomPlan instruction/termination mirrors, and ARKit tracking-state
mirrors. Those categories never claim geometric accuracy. Phase 2B adds a
black SwiftUI semantic Canvas, explicit attempt-local scratch outside the
authoritative project root, a deterministic simulated driver for UI tests, and
a compile-intended iOS-only production adapter. The adapter owns one
`RoomCaptureView` per leased driver and derives that view's single
`RoomCaptureSession` and `ARSession`. It delegates RoomPlan through the view and
session, and reconfigures only that same AR session when probing optional scene
reconstruction; it creates no AVCapture session, picker, second AR session, or
second camera owner.
Camera permission follows explicit Prepare; one-shot GPS follows explicit user
choice. GPS authorization and reference-photo callbacks are attempt-tokenized.
A cancelled GPS request is resumed and cleared before terminal routing; a live
capture termination also emits attempt-scoped location cancellation while the
failure UI is shown. Every queued camera, start, GPS, processing, and photo
effect checks cancellation and the current attempt/phase before entering its
dependency. The production provider retains a fresh manager/proxy identity per
request, and a stale pre-request cached fix resolves as nonfatal no-fix rather
than leaking its continuation. A late callback cannot attach to the next
attempt. Semantic warnings and
operational coaching/tracking/light warnings are maintained separately and
rendered as a de-duplicated union, including explicit empty recovery updates.
A reference photo may be requested only while capture is scanning; exactly one
may be in flight, Stop is blocked until it succeeds or fails, and pre-save
Discard terminates the driver then cleans scratch data. Review does not open a
second camera session.
RoomPlan `didAdd`, `didRemove`, and `didChange` callbacks are treated as
partial deltas and never replace the full semantic Canvas snapshot; V1 admits
only `didUpdate` to that handler. When processing completes, its prepared
semantic snapshot becomes the review and persistence truth; same-token live
snapshots are accepted only through the live/processing phases and cannot
replace review data. Scratch cleanup first synchronously cancels queued effects,
then cancels and awaits tracked start/photo/processing tasks plus the
driver-owned writer barrier. For the
Apple adapter it also retains session ownership until the matching asynchronous
`didEndWith` callback is observed; a bounded timeout leaves the cleanup state
retryable rather than clearing ownership. A cleanup error retains the workspace
and an explicit retry path; it never fabricates a terminal state. Scratch owns a dedicated sibling
root, rejects symbolic root/attempt paths, and startup recovery removes only
validated direct `attempt-*` children. The V1 single-scene app holds an
in-memory coordinator lease so repeated SwiftUI route acquisition cannot create
another driver during an attempt. Back navigation and interactive dismissal are
blocked after an attempt starts; the explicit Close/Discard route completes
cleanup before navigation. GPS remains optional but Save is blocked while its
tokenized request is in flight, preventing an unvalidated late fix from being
attached.
`.saving` remains non-cancelable because persistence may already be promoting
the explicitly accepted package. On Stop, the V1 adapter calls
`stop(pauseARSession: true)` for privacy and one-room finalization; it does not
claim coordinate continuity for a future rescan. It writes required raw
CapturedRoomData JSON, processed CapturedRoom JSON, and native USDZ evidence
plus a thumbnail before review, while raw mesh/world map/provenance remain
explicit omissions until physical proof. Even when scene mesh capability is
available, V1 states honestly that it does not collect raw mesh. The required
dark or black scanning canvas, actual RoomPlan interaction, and high-resolution
photo behavior are still physical-device gates; the photo API signature itself
compiled in hosted Xcode 16.4. A capture-termination callback is
accepted only during starting, scanning, or stopping; a late callback after
review is ignored even when its attempt token matches.

## Phase-4 saved-room viewer and editor

The viewer is intentionally not an AR or captured-mesh viewer. Its iOS adapter
uses `ARView(frame:cameraMode:automaticallyConfigureSession:)` with `.nonAR`
and `automaticallyConfigureSession: false`, an explicit `PerspectiveCamera`,
and only disposable boxes derived from the normalized semantic snapshot.
It never starts, configures, or runs an AR session; it never requests camera
permission. Five root entities represent structural surfaces, objects,
measurements, annotations, and photo markers. `isEnabled` toggles only their
render projections. Planar surfaces receive display-only thickness, and photo
markers use a stored camera-transform translation; neither changes package
truth or claims native mesh/photo rendering.

`RoomViewerCamera` and its reducer remain Foundation-only. Orbit and preset
poses are finite/clamped and the reset pose is derived from the same
yaw/pitch/distance formula. First-person is explicitly collision-free/no-clip;
its forward movement and renderer look direction are derived from current
yaw/pitch rather than a stale orbit target. The SwiftUI gesture layer feeds
incremental rather than cumulative drag/magnification deltas.

`RoomRevisionEditor` is a value-type, copy-on-write semantic draft. It supports
labels, same-layer categories, dimensions, pose adjustment, deletion, manually
provenanced objects, anchored annotations, point-to-point measurements, and
photo captions. A label/dimension edit does not rewrite a captured transform;
an explicit yaw adjustment preserves the existing pitch/roll/scale basis.
Save applies and validates any pending form values before calling the only app
edit path: `commitEditRevision(projectID:expectedHeadRevisionID:payload:)`.
That store transaction reloads under the canonical root lock, requires the
exact current head, stages all parent regular noncanonical assets (including
photos, evidence, and future attachments), preserves evidence compatibility,
and appends one immutable `.edit`. It updates the manifest head last. Cancel
does not call the store; stale conflicts and faults leave parent bytes/history
unchanged and remain visible to the editor.

MockRoom-v1 now includes transforms/polygons, an anchored note, anchored
measurements, and a photo pose marker while retaining its stable IDs and seven
JSON documents. Its bundled deterministic PNG is staged to the declared
revision photo path only after explicit fixture Save.

The narrow RealityKit API surface compiled in hosted Xcode 16.4. Physical-device
rendering and visual inspection remain open gates; host-static evidence alone
does not establish either behavior.

## Phase-5 head-revision export

Export is a frozen handoff of exactly one current immutable head revision, not
a package backup and not full revision history. The only public store entry is
`materializeHeadForExport(projectID:expectedHeadRevisionID:into:)`. Under the
canonical same-process root lock it recovers/loads/fully validates the package,
requires the expected head, rejects destinations inside `Projects` and unsafe
or preexisting destinations, streams copies into a fresh owned external stage,
then promotes that stage before releasing the lock. It does not expose package
URLs to the UI or derived-output layer.

The materialization contains six head documents (`metadata.json`, head
`revision.json`, semantic, annotations, measurements, and photos), but the
three documents with asset references are rewritten to static outbound names:
project thumbnail becomes `assets/thumbnail.<ext>`, photos become
`assets/photos/photo-<index>-<id>.<ext>`, and present evidence uses a fixed
native/evidence path. `source-map.json` records unambiguous project-root versus
revision-root original references for inspection. Every rewritten reference must
name one materialized entry. The project `manifest.json`, older revisions,
pending/ownership files, package exports, and unreferenced paths are excluded.
Declared present native USDZ is copied byte-for-byte; a deterministic fixture
with unavailable native evidence reports a stable skip. Historical plan-less
evidence is never described as complete.

`RoomHeadExportBuilder` adds UIKit-produced derived files only after the store
lock is gone. Foundation validates their bounded PNG/PDF profile and writes a
classic ZIP32 STORE archive: app-owned ASCII entry names; UTF-8 bit; fixed DOS
1980-01-01 timestamp; no compression, directory records, data descriptors,
extras, comments, encryption, or ZIP64. It preflights CRC-32/SHA-256/size in
bounded chunks, writes a manifest of every non-manifest entry under
`integrityScope=allEntriesExceptManifest`, streams a second pass while checking
the same digest, structurally inspects local/central records, and only then
renames an owned `.partial` archive. The archive and manifest are deliberately
not self-hashed. The final cap is 4096 entries; the materializer reserves the
two required derived entries and manifest, so it admits at most 4093 source
entries. Requested GLB, OBJ, and PLY are stable skipped statuses because no
converter is shipped.

UIKit owns only the derived floor-plan PNG/PDF and `UIActivityViewController`
bridge. The floor plan is a bounded top-down projection of normalized semantic
boxes, including transform orientation; it is not a captured mesh or survey
drawing. The finalized lease persists through share completion/cancel. An
unshared ready export must be explicitly cleaned before Close, and cleanup
failure remains actionable rather than broad-deleting scratch storage. Each
lease has a fixed-schema regular ownership marker. Startup recovery removes
only marker-valid, non-symlink direct lease children; lookalikes and links are
preserved. The exact external format is documented in
[export-format.md](export-format.md).

## Phase-6 optional private backup

Phase 6 is deliberately separate from the Phase-5 head export. A store-owned
full-project materialization reloads and validates the exact current head under
the same-process root lock, then deep-copies the package manifest, metadata,
every revision and its canonical documents, required revision ownership record,
and validated regular assets to a marker-owned external workspace. It excludes
`exports/`, pending/staging/recovery artifacts, links, special files, and unsafe
or case/NFC-colliding package paths. The envelope uses app-owned indexed ASCII
ZIP names plus a canonical `backup-manifest.json` mapping; it never feeds an
arbitrary stored path directly to ZIP extraction.

The snapshot ID is the SHA-256 of the exact canonical manifest bytes and forms
the content-addressed record name. Recovery verifies ZIP local/central closure,
CRC/size/digests, canonical manifest bytes, descriptor fields, package closure,
and the existing package validator in an isolated owned stage. An absent project
restores atomically, identical content is a no-op, and divergent content fails
closed until the user explicitly selects Recover as Copy. Copy recovery rewrites
all package-owned project IDs without changing revision IDs, lineage, or asset
bytes; it does not create an edit revision.

Only the app transport imports CloudKit. It uses an exact operator-supplied
container ID, private zone `RoomScanStudioBackupsV1`, record type
`RSSProjectBackupV1`, a single `CKAsset`, and `.ifServerRecordUnchanged` with
per-record result inspection. It never uses `CKContainer.default()`. List is
read-only when the zone is absent, retains at most 200 valid records, and
counts/skips at most 200 malformed successful descriptors; paging stops after
either representation reaches its cap. The retained subset is sorted locally
and disclosed as incomplete rather than represented as the newest records. A
successfully fetched descriptor that
fails local validation is skipped, counted only up to a bounded maximum, and
never offered for recovery; a per-record CloudKit failure still aborts and maps
the explicit operation. Backup alone may create the zone. Marker-valid
direct scratch leases survive through upload/download/recovery and expose
retryable cleanup; startup only reconciles marker-valid direct children.

No entitlement, team, or guessed container identifier is committed. The
operator setup and unverified device/container gates are in
[icloud-setup.md](icloud-setup.md).

## Local-first and privacy posture

Guest/local use has no login, analytics, default hosted/cloud behavior,
automatic upload, or background synchronization. The optional Slice 4
professional service is default-off and lazily constructed only after explicit
entry; it is not a prerequisite for launch, capture, save, view/edit, legacy
export, AI Room Package construction, Concept Set work, or Share Sheet
preparation. No production provider account or endpoint is configured. Phase 6
stores only a local opt-in preference (false by default); changing it does not
call CloudKit. `RoomProjectIndexRecord` is a small SwiftData
projection of package summaries and uses `ModelConfiguration` with explicit
`groupContainer: .none` and `cloudKitDatabase: .none`, both for persistent and in-memory fallback
configuration. It is rebuilt only after authoritative package enumeration
succeeds, and an index failure leaves package-backed UI data intact. The
explicit private backup path is optional; turning it off leaves local packages
fully usable. Camera and optional location descriptions are explicit in Info.plist.
GPS denial must retain manual location entry.

## Phase-1 local library behavior

`LocalRoomProjectStore` is Foundation-only and has an injected clock, ID
generator, and narrow failure seam for deterministic contract tests. A
process-wide lock serializes complete read/validate/promote/manifest
transactions for stores sharing a canonical root. This is deliberately a
single-process app boundary, not a claim of interprocess or app-extension
coordination.

`RoomProjectListing` isolates a malformed or symlinked sibling package as a
diagnostic while retaining valid summaries. The library UI exposes the count and
retains existing package data on an enumeration/index failure. Metadata edits,
archive state, duplicate, delete, and restore refresh the index after their
authoritative package mutation. Deletion is only a store primitive; the UI
requires a destructive confirmation.

The bundled MockRoom-v1 is not auto-seeded. The capability screen offers its
review as a secondary, explicit path. Only Save writes exactly one new package;
Discard performs no persistence. Its review form can edit a room name and
manual location before Save. Its generated PNG thumbnail is supplied as an
explicit project-scoped asset input, copied only on Save, and rendered from the
store's validated byte-read API. A Phase-2A duplicate is a new one-revision
snapshot that stages the source head's photos, declared revision evidence, and
project thumbnail. It does not copy prior history or derived exports.

## Export rules

Native USD/USDZ is mandatory once capture exists. The app preserves the
validated declared-native artifact in the Phase-5 head export and records its
status in the manifest. GLB, OBJ, and PLY remain explicit skipped outputs: no
ModelIO conversion or third-party converter is shipped. Phase 5 already uses a
Foundation-only classic ZIP32 STORE writer; no ZIP dependency is selected.
Artifact inspection remains a macOS/device gate.

## Phase-1 implementation map

    RoomScanStudio/
      App/                         SwiftUI shell, bootstrap, isolated-test root
      Features/Home/               Home, capability, and package library entry
      Features/RoomLibrary/        Detail, metadata, and revision UI
      Features/RoomCapture/        Live capture flow plus explicit MockRoom review
      Features/RoomViewer/         Fully virtual semantic-box viewer only
      Features/RoomEditor/         In-memory copy-on-write revision editor
      Infrastructure/              File fixture loader, local index, controller
      Fixtures/MockRoom-v1/        Deterministic package fixture
      Resources/                   App icon and privacy manifest
      RoomScanStudioTests/         XCTest capability/fixture tests
      RoomScanStudioUITests/       XCUITest launch/action tests
    RoomScanCore/
      Sources/RoomScanCore/        Foundation-only models and package store
      Tests/RoomScanCoreTests/     Portable XCTest transaction/lineage tests
    Docs/                          This checkpoint and verification records
    Scripts/                       Host-only structure verifier

The package intentionally uses only Foundation and declares macOS 13 plus iOS
17 so it can later be tested with Swift on macOS. The app and its unit-test
target refer to the repository-root local package product; source/PBX wiring is
host-statically checked and was resolved by the hosted Xcode 16.4 matrix.

## Planned proof sequence

1. Host static verifier checks project metadata, local package wiring, plist,
   JSON, seven-document fixture references plus the embedded PNG signature and
   resource memberships, portable package imports,
   accessibility/test contracts, and absence of active signing/cloud configuration.
2. On macOS, resolve package/Xcode compatibility; build all three targets; run
   package XCTest, app XCTest, and UI tests on iPhone and iPad Simulators.
   Completed by hosted run 31359458769 on 2026-08-10.
3. On LiDAR iPhone and iPad, prove runtime support checks, scanning UI, RoomPlan
   capture, save/discard, raw-mesh gate, and the production-rescan unavailable
   safety boundary. Fixture-only rescan is a separate deterministic test path.
4. In a CloudKit development container, prove opt-in snapshots and ensure
   local-only behavior remains operational.
5. Inspect native and optional export artifacts and manifests.

Step 2 has passed in hosted CI. Steps 3 through 5 remain external gates and are
not implied complete by source or Simulator evidence.

## Apple API references

- RoomCaptureSession: https://developer.apple.com/documentation/roomplan/roomcapturesession
- Support check: https://developer.apple.com/documentation/roomplan/roomcapturesession/issupported
- RoomCaptureSession coaching instruction: https://developer.apple.com/documentation/roomplan/roomcapturesession/instruction
- RoomCaptureSession capture error: https://developer.apple.com/documentation/roomplan/roomcapturesession/captureerror
- ARCamera tracking state: https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
- ARCamera limited-tracking reason: https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum/reason
- CapturedRoomData encoding: https://developer.apple.com/documentation/roomplan/capturedroomdata/encode(to:)
- CapturedRoomData decoding: https://developer.apple.com/documentation/roomplan/capturedroomdata/init(from:)
- CapturedRoom export: https://developer.apple.com/documentation/roomplan/capturedroom/export(to:metadataurl:modelprovider:exportoptions:)
- RoomBuilder processing: https://developer.apple.com/documentation/roomplan/roombuilder/capturedroom(from:)
- AR high-resolution frame capture: https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe()
- Single-structure scanning: https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- Scene reconstruction: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- ARWorldMap storage: https://developer.apple.com/documentation/arkit/saving-and-loading-world-data
- SwiftData sync behavior: https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
- CKAsset: https://developer.apple.com/documentation/cloudkit/ckasset
- CKDatabase bulk record lookup: https://developer.apple.com/documentation/cloudkit/ckdatabase/records(for:desiredkeys:)
- CKDatabase bounded-zone query: https://developer.apple.com/documentation/cloudkit/ckdatabase/records(matching:inzonewith:desiredkeys:resultslimit:)
- CKDatabase atomic record modification: https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:)
- CKRecordZone: https://developer.apple.com/documentation/cloudkit/ckrecordzone
- ModelIO exporter predicate: https://developer.apple.com/documentation/modelio/mdlasset/canexportfileextension(_:)

## Phase 7 release delivery boundary

Release metadata is intentionally mechanical: app targets use
`MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1`, and Swift language
mode 5.0, while the portable package stays on Swift tools 5.9. `Info.plist`
substitutes those build settings. The asset catalog declares one opaque RGB
1024x1024 AppIcon source; its host header is inspected without claiming that an
Apple asset compiler rendered it.

The presentation layer has a semantic adaptive paper palette, fixed-dark
instrument roles, Dynamic Type typography, and `AdaptiveActionRow` fallback
layouts. Capture and viewer canvases expose an accessible label/value/hint; the
viewer remains fully non-AR. The host verifier calculates literal WCAG contrast
for paper and dark-canvas roles, including prominent-action label/boundary
pairs. This is a source/value check, not a visual Accessibility Inspector run.

The pinned macOS CI design validates the host oracle, package, unsigned generic
iOS build, dynamically discovered iPhone/iPad Simulator tests, and xcresult
retention. Run 31359458769 passed that complete matrix on Xcode 16.4 at commit
`aa18d6bbedfc4525208653a330dfe216636f5b01`: 122 Core tests, then 62 app tests
and 25 UI tests on each selected simulator. No Phase 7 change adds a team,
entitlement, container, background network behavior, or source-of-truth
migration.

## Slice 4 architecture reconciliation — 2026-08-21

The current local architecture is a default-off iOS professional boundary over
three service-owned composition roots, route contract
`roomscan-slice4-routes-v3` with 19 routes, seven least-privilege PostgreSQL
runtime roles, and the offline infrastructure assembly. Accepted service proof
records explicit context clearing before identity/workspace pre-resolution so
stale pooled transaction-local scope cannot participate in that resolution.
The database then establishes the authorized transaction scope through the
frozen capability surface rather than caller-supplied tenant authority.

Current local/offline evidence is Node 24.15.0 service typecheck/build plus
277/277 tests; a 43-command disposable PostgreSQL 16 matrix with 53/53
integration cases, 14/14 legacy mutations and 46/46 `0007` mutations; and
offline infrastructure at 104/104 tests and 17/17 mutations. The synthesized
delivery has exactly nine declared assets across 28 files, complete migration,
VPC and IAM roots, no orphan/stub markers, and no Slice 7 resources. No Slice 5
project-synchronization implementation is included.

This is not a whole-slice release claim. Local implementation is complete: the
hosted umbrella, Core, complete iPhone/iPad schemes, focused selectors,
Simulator/generic-device artifact inspection, scoped static controls and
bounded Terra reviews are recorded. The controller retains only a final
diff/docs/cleanup handoff audit. Live provider semantics require a separately
authorized non-production packet; physical Face ID/passcode requires owner
evidence; production provisioning and release approval remain pending by
design. No external action, real data, commit, push, PR or deployment occurred,
and the repository is not production-ready.

The final IAM composition removes unconditional Lambda-role `kms:Decrypt` on
the SecretsKey. The allowed path is guarded by an exact Secrets Manager
`ViaService` + `SecretARN` synth oracle and restored mutation. Its focused live
test was observed RED before the fix and GREEN after restoration; live AWS
policy evaluation remains an external gate.
