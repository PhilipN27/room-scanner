# RoomScanStudio AI Redesign Platform Slice 3 Implementation Plan

**Date:** 2026-08-16

**Outcome:** Deliver the complete account-free, offline Slice 3 workflow: build
and review deterministic AI Room Packages, share them through a marker-owned
lease, and import/review/manage revision-bound Concept Sets without modifying
captured source truth.

**Proof:** Focused red/green tests and required mutation controls must pass,
followed by the complete Core/app/iPhone Simulator/iPad Simulator matrix,
independent archive extraction and closure inspection, built-artifact checks,
and the physical LiDAR iPhone protocol when a supported device is available.
Physical-iPad behavior remains owner-waived and unverified.

## Baseline and retained evidence

- Worktree: `/private/tmp/roomscanstudio-ai-redesign-platform-slice3`
- Branch: `agent/ai-redesign-platform-slice3`
- Exact HEAD: `fa864d39ee230cfaa6994dec1574e344770556a9`
- Starting source status: clean; nothing staged.
- Primary checkout: intentionally dirty at an unrelated revision and excluded
  from all Slice 3 writes.
- Slice 2 evidence worktree: preserved, detached, and excluded from writes.
- Toolchain: Xcode 26.3 (17C529), iPhoneOS 26.2 SDK, Swift 6.2.4.
- Resolved packages: MetalSplatter
  `2b965de1934de38dda1c71cf90bf798aa948a14c`, spz-swift 2.1.0,
  swift-argument-parser 1.8.2, and the local RoomScanCore package.
- Fresh baseline: 230/230 RoomScanCore tests and simulator-selector self-test
  pass. The static verifier reports only its pre-existing signing-policy
  conflict with the tracked `DEVELOPMENT_TEAM`; preserve the setting and report
  this exception accurately rather than rewriting signing state.
- Retained Slice 0 contract/threat/SDK evidence, Slice 1 orientation evidence,
  and Slice 2 quality fixtures and Simulator evidence remain valid and are not
  to be recreated. The owner accepts Slice 2 on the physical LiDAR iPhone by
  direct observation, but the retained artifact matrix is only three
  screenshots. The generic `regions` label and repeated tracking guidance
  remain known limitations. Physical iPad remains waived and unverified.

## Scope and non-goals

This plan implements only the nine Slice 3 roadmap entries and reconciles the
Slice 2 owner-acceptance wording. It does not add accounts, hosted APIs, model
calls, provider SDKs, direct-chat insertion, uploads, billing, portal/public
links, cross-room inference, precise-GPS or world-map export, destructive
redaction, or any Slice 4+ behavior. Concepts remain additive companion state;
they never edit source geometry, measurements, evidence, images, quality, or
revision history. The Slice 2 detector and presentation are not redesigned.

## Existing substrate and gaps

- `RoomRedesignSourceRevision`, `RoomOrientationContractV2`,
  `RoomRedesignIntentV2`, and `RoomQualityReportCarrierV1` already provide exact
  project/revision/epoch/semantic/manifest binding, deterministic cameras,
  intent/permissions, and unchanged quality carriage.
- `RoomAIRoomPackage`, its strict duplicate/unknown-key decoder, disclosure
  review, artifact ledger, plan/selection digests, raw/GPS/world-map guards,
  and the portal archive validator are the starting contract authority.
- `RoomDeterministicZIP` supplies deterministic ZIP32 STORE output and strict,
  bounded extraction; head export supplies the preflight/build/share pattern;
  backup recovery supplies marker-owned stage/validate/promote/rollback.
- Capture sidecars contain posed RGB/depth/confidence metadata and reusable
  sharpness analysis, but are currently project-scoped rather than exact
  revision-bound. Unbound legacy sidecars must be recorded unavailable.
- Canonical cameras and floor-plan projection are reusable. Canonical rendering,
  hostile-media decoding/re-encoding, package production, and Concept import
  do not yet exist. Material truth is not currently captured; it must be an
  honest unavailable ledger record unless a validated texture source exists.
- The existing Share Sheet correctly holds leases through completion/cancel,
  has dismissal fallback and iPad popover anchoring, but must carry an explicit
  error result for Slice 3. The existing redesign companion stores one JSON
  document only and cannot atomically own Concept attachments.
- The production guest graph is locally rooted and the static verifier rejects
  HTTP/auth/hosted imports and symbols. Slice 3 extends that same graph and its
  positive injected-network control.

## Contract and archive design

### Artifact plan and ledger

The v1 manifest remains `roomscan-ai-room-package-v1`, but its production plan
is realized as deterministic artifact slots identified by stable `artifactID`
plus `artifactClass`. Repeated classes are permitted for canonical views,
selected images, textures, diagnostics, and provider instructions. Every
planned slot has exactly one ledger record and no unplanned record is accepted.

Canonical order is artifact-class rank, then ASCII artifact ID. The plan digest
is SHA-256 of canonical JSON containing schema/profile, the exact source
revision binding, and ordered `{artifactID, artifactClass}` slots. The selection
digest is SHA-256 of the ordered full ledger projection. Included records carry
one portable relative ASCII path, lowercase SHA-256, positive byte count, and
allowlisted media type. Other dispositions carry no byte fields and one stable
reason code. Manifest bytes are canonical JSON and must be byte-identical after
strict decode/re-encode.

The archive layout is flatly bounded and closed:

```
manifest.json
truth/semantic-model.json
truth/revision-lineage.json
truth/orientation.json
truth/canonical-cameras.json
derivatives/floor-plan.png
derivatives/canonical-views/<camera-id>.png
references/<selection-id>.jpg
appearance/materials.json
appearance/textures/<texture-id>.png
quality/quality-report-carrier.json
brief/room-brief.txt
intent/redesign-intent.json
instructions/provider-neutral.txt
instructions/chatgpt.txt
instructions/claude.txt
instructions/grok.txt
geometry/<artifact-id>.<ext>
raw/<artifact-id>.<ext>
diagnostics/<artifact-id>.json
```

Only included ledger paths may exist in addition to `manifest.json`; every
included path must exist once with matching digest/size/media type. Archive
output uses deterministic STORE ZIP headers and is independently extracted into
an owned empty stage before the lease becomes shareable. Unknown versions/keys,
duplicate JSON keys, noncanonical manifests, malformed or colliding paths,
rebinding, unledgered entries, inconsistent bytes, and unsupported media fail
closed.

### Profile rules

AI-ready is the default. Its plan covers normalized semantics, immutable
lineage, confirmed/manual orientation plus axes/cameras, floor plan, six bounded
canonical views, at most four deterministically selected sharp posed images,
available materials/textures, exact quality carrier or unavailable record,
human brief, verbatim intent/constraints/permissions/scope, four instruction
files, and a bounded available mesh/texture projection. Raw RGB sequences,
depth, confidence, diagnostics, world maps, GPS, private notes, full metadata,
and undeclared evidence are not valid AI-ready plan slots.

Complete contains every AI-ready slot with the same ID and selected bytes, then
adds bounded extra selected images, meshes, textures, raw RGB/depth/confidence,
and diagnostics when available. It is valid without raw evidence, but included
raw slots require exact explicit raw-disclosure approval. Neither profile has a
world-map or precise-GPS slot. Missing optional inputs are `unavailable`; an
intentional user choice is `excluded`; policy omissions are `skipped`; producer
errors are `failed` and block sharing until the reviewed selection is rebuilt.

### Readiness, quality, and selection

Production planning first obtains a validated immutable source binding from
`LocalRoomProjectStore`. It then requires an exact companion match, confirmed
or manual orientation, nonempty verbatim request, valid constraints, and unique
per-feature permissions. Suggested/missing/rebound orientation or any source
digest/epoch mismatch fails before planning. Quality is advisory: when present,
the exact canonical report plus its Save Anyway acknowledgement and digest is
carried unchanged in `RoomQualityReportCarrierV1`; legacy absence is never
fabricated and is ledgered unavailable.

Posed candidates must be exact revision/epoch-bound. Selection sorts by finite
sharpness descending, then timestamp, then stable evidence ID, with fixed
profile caps; ties are deterministic. Unbound legacy capture bundles are not
silently rebound. Clocks and identifier providers are injected into builders,
reviews, imports, and fixtures. Rendering, sanitization, hashing, and ZIP work
run in services/tasks outside SwiftUI and capture callbacks.

Four deterministic instruction templates may vary phrasing/workflow hints but
embed the same source, truth, permission, quality, and selection digests. Each
states that external models may not follow every instruction and that Renovate
and Reimagine output is conceptual. No current provider capability claim is
made or tested without fresh official evidence.

## Disclosure and media boundary

The disclosure coordinator has `draft`, `pending`, `approved`, `rejected`,
`stale`, `building`, `ready`, and `failed` states. Review shows the exact
profile, inventory/dispositions/reasons, selected sanitized image previews and
metadata, estimated size, quality advisories, structural GPS exclusion,
Complete raw warning/consent, and external-provider privacy/account notice.
Approval binds review ID/time, exact source revision and revision-manifest
digest, plan digest, and full selection digest. Any exclude, replacement,
profile, plan, path, digest, or disposition change creates a new selection and
invalidates approval. Pending/rejected/stale/replayed/wrong-source approvals
cannot build or share.

ImageIO adaptation accepts only byte-verified single-image JPEG and PNG within
fixed byte/pixel/dimension budgets. It validates complete JPEG/PNG framing,
decodes exactly once, rejects unsupported/active/mislabeled/polyglot/trailing
content, then renders and re-encodes a fresh sRGB raster without EXIF, GPS, XMP,
comments, auxiliary images, or external references. Advisory Vision analysis
may report possible face/person/text plus conservative document/screen/address/
family-photo/reflective-surface prompts. The UI says detection is incomplete
and performs no automatic destructive redaction. Users can exclude a candidate
or choose a separately sanitized replacement.

## Concept Set design

Core adds a standalone strict `roomscan-concept-set-v1` manifest. It binds one
existing immutable source revision and records request/scope, optional provider,
optional source AI-package schema/ID for packaged output, created/imported
times, per-attachment content identity, sanitization provenance, approval and
archive states, comments, and one mapping per attachment:

- `automatic(cameraID)`: only an exact source-bound canonical camera/view ID
  declared by the package and present in the current orientation;
- `manual(cameraID)`: an explicit user selection from current canonical IDs;
- `unmatched`: the default whenever exact evidence is absent or ambiguous.

No image-content confidence is invented. Loose imports have explicit local-file
provenance and provider remains absent unless the user discloses it.

Loose import accepts one bounded byte-verified JPEG/PNG. Packaged import accepts
only the documented deterministic ZIP32 STORE Concept Set profile. The strict
extractor and manifest validator enforce file/byte/pixel/entry/total limits,
portable paths, Unicode/case collision rejection, CRC/digests, closure, no
links/special files/nested archives/external URLs, and media re-sanitization.
Unsupported compression is rejected rather than decompressed, making its
compression-ratio bound exactly 1:1 and nesting depth zero.

`LocalRoomConceptStore` uses marker-owned same-root staging, canonical metadata,
attachment-byte verification, a per-source transaction lock, atomic promotion,
and recovery cleanup. Failed/cancelled imports publish nothing. Archive/
unarchive updates only the chosen Concept Set atomically; explicit deletion
removes only its proven marker-owned directory. List/reopen validates every byte
and exact source binding. The source package is never in the store's write root.

## Ownership boundaries

- **RoomScanCore:** plan/ledger schemas and strict decoders, readiness and
  deterministic selection, canonical serializers/digests, package/Concept
  archive validation, Concept provenance/mapping contracts, transaction/store
  semantics, and source-immutability checks.
- **iOS infrastructure:** source/capture adaptation, canonical rendering,
  ImageIO sanitization and Vision advisories, security-scoped import, disclosure
  coordinator, package service, marker-owned share lease, and persistence
  integration.
- **SwiftUI:** profile/brief/readiness, disclosure and image actions, explicit
  Share Sheet, Concept list/detail/import/mapping/comparison/archive/delete,
  confirmation, accessibility, and responsive presentation.
- **External providers:** generated results and their own account/privacy terms;
  RoomScanStudio makes no compliance guarantee.

## Ordered implementation

1. Reconcile only Slice 2 acceptance wording; add this plan and preserve all
   existing evidence.
2. Write failing Core tests for deterministic slots/digests, repeated classes,
   profile superset/raw/GPS/world-map rules, readiness, quality carriage,
   provider-template truth equivalence, archive round-trip/closure, and source
   byte immutability. Implement the planner, builder, and validator minimally.
3. Write failing Core tests for standalone Concept manifests, automatic/manual/
   unmatched mapping, strict loose/package validation, hostile archives, atomic
   stage/promotion/recovery, persistence/reopen, archive/delete isolation, and
   cancellation/failure. Implement contracts, importer, and store minimally.
4. Write failing app tests for sanitized JPEG/PNG, rejected hostile media,
   advisory boundaries, exact disclosure invalidation, capture/source adapters,
   asynchronous build, Share Sheet completion/cancel/error/fallback cleanup,
   file import, offline graph, and source-byte controls. Implement iOS services.
5. Load `frontend-design` before UI code; add focused SwiftUI and UI tests for
   the complete review/share/Concept lifecycle, wire AppEnvironment/controller,
   and add all PBX references/phases and static verifier rules.
6. Run the required eight mutation controls: orientation gate; disclosure
   plan/selection binding; AI-ready raw guard; GPS/world-map guard; unledgered
   archive entry; Concept source binding/atomic promotion; injected HTTP client;
   and share-lease cleanup. Each live guard is temporarily neutralized only long
   enough to record the focused red, then restored and rerun green.
7. Build deterministic positive/negative fixtures and capture the Simulator UI
   matrix. Inspect desktop review at each state and iterate once for hierarchy,
   clipping, Dynamic Type, contrast, labels, focus, non-color cues, and targets.
8. Run final Core/app/static/selector/package-resolution/generic-build/iPhone/
   iPad/built-artifact/archive/diff/staging checks and update authoritative docs
   only for obtained evidence.
9. If a supported LiDAR iPhone is available, execute and retain the full package,
   Share Sheet, import, mapping, persistence, archive/delete, and before/after
   source-digest protocol. Otherwise record the exact open physical gate and do
   not call Slice 3 physically complete.

## Fixture and visual matrix

Core fixtures cover every requested profile/quality/orientation/rebinding/
review/ledger/JSON/archive/media/Concept/mapping/persistence case, including
positive controls for reviewed raw evidence and safe sanitized images. Malicious
ZIP cases are hand-authored or byte-mutated because the safe writer cannot emit
them. Each negative probe has a reachable positive control.

Simulator screenshots use both iPhone and iPad, light and dark, default and an
accessibility Dynamic Type size. Stable evidence states cover: profile choice;
brief/permissions/readiness; artifact/image review and advisory flags;
exclude/replacement and GPS exclusion; Complete raw consent; package ready;
Concept import and automatic/manual/unmatched mapping; original comparison;
persisted reopen; archive; and delete confirmation. VoiceOver labels/order,
focus, non-color distinctions, touch targets, long text, and action clipping are
checked explicitly. Simulator Share Sheet imagery is not physical-device proof.

## Rollback and completion boundary

The rollback point is exact commit `fa864d39ee230cfaa6994dec1574e344770556a9`.
Legacy export and immutable room packages remain untouched; AI archives are
temporary leases, and Concepts are independently removable companion state.
Nothing is staged, committed, pushed, uploaded, provisioned, or changed in an
external system. Slice 4 remains untouched.
