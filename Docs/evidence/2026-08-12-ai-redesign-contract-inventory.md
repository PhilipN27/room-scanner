# AI redesign contract inventory

- Date: 2026-08-12
- Baseline: branch `agent/ai-redesign-platform-plan`, commit `362c8cd`
- Purpose: classify the existing persisted boundaries before adding Slice 0
  contracts

## Existing authoritative contracts

| Boundary | Current contract | Observed behavior | AI redesign consequence |
| --- | --- | --- | --- |
| Local project package | `room-scan-project-v1` and `room-scan-project-v2`; new projects use v2 | The manifest names one immutable head and revision lineage. Append validates/stages/promotes a new revision and preserves the package's existing schema version. Legacy v1 fields and missing evidence compatibility still decode. | Keep package bytes as truth. New redesign data is a separately versioned revision-bound extension until an explicit validate-stage-promote package migration is designed. |
| Revision evidence | Strict v2 evidence plan plus a legacy v1 compatibility mode | IDs, provenance, dimensions, transforms, declared paths, size, digest, namespace closure, and evidence directory closure are validated. | New outbound/sync records reference a validated immutable revision and digest. They do not weaken existing closure checks or rewrite prior revisions. |
| Head export | `roomscan-head-export-v1` | Exports only the validated current head and explicit derivatives; it is distinct from backup and has its own closure/size checks. | AI Room Package is a new profile/version alongside head export, not a reinterpretation of this format. |
| Full-project backup | `roomscan-project-backup-v1`, descriptor magic `rssb1` | Explicit private CloudKit custom-zone action stores a validated full project as a CKAsset, with conditional replacement and recovery-copy validation. It is not invoked on launch or a generic toggle. | Leave this private Apple-account backup unchanged. Professional sync is a separate hosted contract and identity/tenancy boundary. |
| Capture commit | `RoomInitialCaptureCommit` plus the capture reducer/coordinator | RoomPlan and the one retained AR session produce a staged local package only on Save. GPS/photos are optional. Discard cleans scratch state. No hosted auth or server dependency participates. | Guest capture remains local/offline. Any later migration starts from a validated saved package and never deletes the local source as part of upload. |
| Capture sidecar | Capture bundle manifest schema v3 outside the project package | Best-effort high-volume RGB/mesh/depth/confidence/diagnostic evidence is stored separately from package truth. Training ZIP export is another explicit action. | Default sync must not discover or upload this directory implicitly. A future raw archive needs an explicit revision binding, owner opt-in, size/privacy review, and distinct asset policy. |
| Viewer/editor | Disposable non-AR render state plus copy-on-write edit revisions | The saved-room viewer renders semantic boxes/derived mesh without starting capture. Edits append a new revision under an expected local head. | Concepts, orientation, and presentation metadata remain additive and cannot become an alternate mutable geometry authority. |

Repository source and app tests contain no general `URLSession`, OAuth,
bearer-token, hosted-service SDK, or professional-auth path. Network/account
behavior is confined to existing explicit Apple services such as private
CloudKit backup and OS authorization APIs. The current executable guest route
remains:

```text
launch -> capture or fixture -> review -> local save -> local view/edit
       -> head export -> Share Sheet
```

The approved future AI package construction and Concept Set import operations
sit on the same account-free, offline side of the boundary. Slice 0 defines
their contracts only. Nothing in this slice changes the executable route or
makes server availability a precondition.

Slice 0 executes the currently available local portion through an in-process
`AppEnvironment` integration test: simulated capture, explicit Save, package
load/edit, legacy head-export preparation, and scoped export cleanup. A
test-only HTTP(S) transport catches a deliberately injected request. On the
installed iOS 26.3.1 Simulator, global `URLProtocol` registration did not
intercept newly created default or ephemeral sessions, so a companion static
oracle rejects production HTTP/auth clients and proves its detector with an
in-memory injected `URLSession` control. This combined evidence does not claim
the future AI-package/Concept Set paths or a physical system Share Sheet.

## Additive fields and documents

The following data can be added as new optional/versioned documents bound to an
immutable source revision without changing legacy package decoding:

- confirmed entry position/inward direction, source/confidence, canonical axes,
  cameras, and coordinate-space epoch;
- separate sharpness, coverage, tracking, and semantic-identification quality
  records and stable warnings;
- the verbatim redesign request, optional structured constraints, Stage /
  Renovate / Reimagine scope, and per-feature permissions;
- property membership that groups independent rooms without transforms,
  alignment, doorway connectivity, or whole-property spatial claims;
- Concept Set metadata, provenance, canonical/manual/unmatched mapping,
  approvals/comments/archive state, and attachment references;
- AI-package manifests and disclosure review;
- hosted resource, working-sync, and published-snapshot envelopes.

These extensions must contain the source project ID, immutable revision ID,
coordinate-space epoch where spatial interpretation applies, immutable revision
manifest digest, and distinct semantic digest. Referenced attachments retain
their own digests. A cross-revision concept, orientation, or derivative is
invalid rather than silently rebound.

## Changes that require a migration or explicit readiness gate

The following cannot be made required inside the current canonical v1/v2
documents without a new package version and a validate-stage-promote migration:

- canonical entry/orientation fields;
- quality reports;
- redesign intent and permissions;
- concept/property records;
- a mandatory AI manifest; or
- a required capture-sidecar reference.

Existing append behavior intentionally preserves an old package's schema
version, so a new required field cannot be smuggled into legacy packages by an
ordinary revision append. Until a migration exists, AI export and publication
use an explicit readiness gate: the source package still opens unchanged, but
the new operation requires its own complete, valid revision-bound extension.

## New independent contract boundaries

- **AI-ready / Complete package:** provider-neutral outbound manifest with an
  exact artifact disposition for every deterministic required slot and every
  optional requested item. It coexists with legacy head export. Complete is an
  explicit superset; neither profile has a precise GPS field.
- **Working-project sync:** expected-head append request and recoverable asset
  set. The default policy structurally excludes raw frame/depth/confidence and
  diagnostics; raw archive is a separately reviewed opt-in.
- **Hosted API resource:** versioned vendor-neutral resource envelope. Vendor
  identifiers or SDK objects do not enter `RoomScanCore`.
- **Portal snapshot:** separate immutable allowlisted resource/asset graph. It
  is constructed from an empty snapshot, never from a private package by
  subtraction.

These contracts introduce no migration, production database, endpoint,
credential, dependency, or network call in Slice 0.
