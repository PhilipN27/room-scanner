# RoomScanStudio AI Redesign Platform Implementation Roadmap

> **Implementation guidance:** Use Ultra for the complete multi-slice program.
> Use Max for a focused slice. Enter plan mode before each slice, use red-green
> tests for new correctness guards, and do not claim device, network, privacy,
> or deletion behavior from a build alone.

**Goal:** Implement the approved orientation-aware AI Room Package, quality
guidance, Concept Sets, professional workspace, immutable sync, and interactive
client portal while preserving a fully useful account-free local app.

**Authoritative design:**
`Docs/superpowers/specs/2026-08-12-ai-redesign-platform-design.md`

**Architecture:** Keep immutable local room packages as capture truth. Add
versioned provider-neutral interchange contracts in RoomScanCore, native iOS
capture/review/share/import flows, a separately selected professional service,
a lightweight professional web workspace, and allowlisted immutable portal
snapshots. Do not repurpose private CloudKit backup as multi-tenant sync.

## Global constraints

- Preserve all pre-existing room packages and revision lineage.
- Guest mode performs no login or hosted call and remains usable offline.
- No core workflow charges RoomScanStudio for model inference.
- Verify Apple APIs against the installed SDK and physical LiDAR hardware.
- Keep expensive visual analysis out of the capture hot path.
- Never silently merge sync conflicts or upload raw capture evidence by default.
- Never construct a public snapshot by copying a complete private package and
  deleting a list of known-sensitive files.
- No E2EE, survey, construction, external-model-compliance, or multi-room-
  reconstruction claims.
- Treat the existing uncommitted worktree as user-owned. Do not overwrite or
  stage unrelated changes.

## Ownership boundaries

| Boundary | Responsibility | Must not own |
| --- | --- | --- |
| RoomScanCore | Versioned models, validation, manifests, constraints, orientation, quality, concepts | UI, authentication, network vendors |
| iOS app | Capture, review, Face ID, local editing, package/share/import, offline drafts | Hosted canonical database or browser rendering |
| Hosted API | Identity mapping, authorization, expected-head coordination, projects, snapshots, retention | Capture truth generation or model inference |
| Object storage | Validated encrypted assets and lifecycle classes | Authorization decisions |
| Professional web | Workspace/property/link/member/billing/review management | Capture or full spatial editing |
| Client portal | Read-only snapshot rendering and verified feedback | Live project access or project mutation |

## Slice 0: Plan revision, feasibility, and service decision

**Outcome:** Convert the approved design into versioned contracts and choose a
hosted architecture using evidence rather than prematurely coding against a
vendor.

- [x] Re-read the master plan, approved design, current architecture/privacy/
  export/backup docs, repository instructions, and relevant memory.
- [x] Inventory current local package, export, backup, capture, and viewer
  contracts; identify additive versus migration-requiring fields.
- [x] Verify installed Apple SDK APIs used by entry orientation, RoomPlan
  categories, AR camera poses, depth/confidence, Face ID, and Share Sheet.
- [x] Write an architecture decision record comparing at least two viable
  U.S.-region service stacks against conditional writes, row/tenant isolation,
  signed object access, encryption, lifecycle deletion, auditability, web
  deployment, email/Apple identity, subscription billing, local development,
  and measured operating cost.
- [x] Define versioned schemas for local extensions, hosted API resources,
  AI-ready/Complete packages, working-project sync, and portal snapshots.
- [x] Produce a threat model covering cross-tenant access, bearer links, PINs,
  session theft, upload validation, malicious archives, operator access,
  deletion, and publication kill switch.

**Oracle:** Schema fixtures validate and reject malformed/cross-version input;
an ADR records evidence and rejected alternatives; a clean baseline build/test
matrix passes before product code changes; no server dependency appears on the
guest launch/capture/export path.

**Rollback:** No production data or network path is introduced in this slice.

## Slice 1: Spatial truth, orientation, semantics, and property containers

**Outcome:** Add the local data needed by all later packages and portals.

- [x] Add additive, versioned models for confirmed entry position/direction,
  canonical axes/cameras, orientation source/confidence, property containers,
  redesign permissions, hybrid briefs, and Concept Set provenance.
- [x] Preserve backward decoding of every current package and fixture.
- [x] Add an orientation review step that suggests but requires confirmation
  before AI export/publishing; support manual reference-wall fallback.
- [x] Generate deterministic entry, wall, corner, orbit, perspective, and
  top-down camera definitions from normalized room coordinates.
- [x] Give walls, doors, windows, openings, floor, ceiling, fixed, movable, and
  unknown elements distinct semantic tokens, legends, and accessibility text.
- [x] Add lightweight property grouping without any cross-room transform or
  doorway inference.

**Oracle:** Old fixtures load unchanged; new schemas round-trip deterministically;
invalid/non-finite orientation transforms fail closed; original revision bytes
remain unchanged; unit fixtures prove canonical cameras; iPhone/iPad screenshots
prove semantic distinctions in light/dark and accessible presentation.

**Guard proof:** Temporarily neutralize the orientation-required export guard;
the focused negative test must fail, then pass after restoration.

**Rollback:** New fields are optional for legacy viewing; disable new review/UI
without altering stored legacy projects.

**Slice 1 status (2026-08-13):** Local implementation and Simulator evidence
are complete. The owner accepted corrected orientation behavior on the
physical LiDAR iPhone. Physical-iPad acceptance is waived for the current
program and remains explicitly unverified, not passed or failed.

**Device-discovered correction (2026-08-13):** The top-down review now matches
the semantic viewer by default and supports presentation-only Rotate 90°,
Mirror, and Reset with local persistence. Complete iPhone and iPad Simulator
schemes pass 153/153. The owner accepted the corrected physical-iPhone
behavior; physical iPad remains waived and unverified.

## Slice 2: Live and finish-time quality guidance

**Outcome:** Produce honest location-specific scan coaching and a persistent
four-dimension quality report.

- [x] Define bounded quality records for sharpness, coverage, tracking, and
  semantic identification, each with evidence, affected regions, confidence,
  and stable reason codes.
- [x] Reuse existing posed keyframes and frame sharpness analysis to aggregate
  visual quality into room-space regions after bounded per-frame work.
- [x] Add lightweight live coaching without decoding or scoring full images on
  the capture hot path.
- [x] Add coverage overlays and specific revisit guidance.
- [x] Add a recommended Finish gate, structured review summary, and explicit
  Save Anyway action that records weak regions in the immutable revision.
- [x] Define one unchanged provider-neutral quality-report carrier for future
  AI packages and published snapshots. Actual package construction and portal
  publication remain owned by Slices 3 and 6 respectively.

**Oracle:** Deterministic sharp, blurred, uncovered, low-confidence, and
tracking-limited fixtures exercise each independent warning; controls prove
the detector reaches the unsafe paths; Save Anyway persists exact warning
provenance; a supported LiDAR iPhone session deliberately captures good and
bad controls and visually confirms region mapping. The complete iPad Simulator
scheme remains required; physical-iPad behavior is waived and unverified.

**Rollback:** Quality coaching is advisory and feature-gated; capture/save
continues with the existing general guidance if localized analysis fails.

**Slice 2 status (reconciled 2026-08-16):** Implementation, deterministic
fixtures, mutation controls, and focused iPhone/iPad Simulator UI evidence are
complete. The owner accepts Slice 2 on the physical LiDAR iPhone based on direct
observation. Only three physical-run screenshots were retained; they are not a
complete independent artifact/device-metadata matrix. The generic `regions`
label and repeated tracking guidance remain known limitations. Physical iPad
is waived and unverified. The Norwalk YMCA example remains deferred until the
whole application is complete. Slice 3 implementation is governed by
[the dedicated Slice 3 plan](2026-08-16-ai-redesign-platform-slice-3.md).

## Slice 3: AI Room Package, disclosure review, and Concept Sets

**Outcome:** Complete the guaranteed local user-funded AI preparation and
Concept workflow; provider execution and physical delivery remain external.

- [x] Implement canonical provider-neutral package schemas and manifests.
- [x] Build AI-ready selection from semantic truth, orientation, quality,
  canonical views, and bounded sharp posed images.
- [x] Build Complete as an explicit superset with additional available meshes,
  textures, images, depth/confidence, and diagnostics.
- [x] Encode required free-form intent, optional structured constraints, Stage/
  Renovate/Reimagine, and per-feature `preserve`/`mayChange`/`requestedChange`.
- [x] Generate offline provider-tailored instruction files without changing
  underlying truth; direct-chat insertion remains an unimplemented and
  unverified optional adapter.
- [x] Add mandatory outbound privacy review, advisory sensitive-content flags,
  image exclusion/replacement, and default precise-GPS exclusion.
- [x] Deliver through the existing iOS Share Sheet with owned lease cleanup in
  the local/Simulator lifecycle.
- [x] Import loose or packaged outputs as revision-bound Concept Sets; map to
  canonical views automatically only with authenticated finalized-package
  provenance and a current declared view, otherwise manually or unmatched.
- [x] Add original-versus-concept comparison and concept archive/delete flows.

**Local oracle:** Golden AI-ready and Complete fixtures pass schema, manifest,
checksum, and archive-closure tests; every requested artifact has an included/
excluded/skipped/failed record; GPS/raw-default negative tests include positive
controls; package extraction succeeds independently; local Share Sheet lifecycle
cleanup is exercised; concept import/delete cannot change semantic geometry,
measurements, or source revision digests. Physical Share Sheet targets,
security-scoped import, completion/cancel/error/dismissal, and provider behavior
remain separate unchecked gates.

**Rollback:** Package versions coexist with the legacy head export. Concepts
are additive attachments and can be hidden without altering source rooms.

**Slice 3 local/Simulator status (2026-08-17):** Complete: 266/266 Core tests;
complete 219/219 schemes (185 app + 34 UI) on each iPhone 16 Pro and iPad (10th
generation) Simulator; and focused Slice 3 UI evidence of 5/5 on each form
factor. The final local proof includes deterministic AI-ready/Complete archive
extraction/closure, authenticated finalized-package Concept automatic mapping,
local Share Sheet lease cleanup, and no provider/model/auth/direct-HTTP client
in the production AIRedesign path. This does not authorize or imply Slice 4
work. Physical LiDAR iPhone Share Sheet/import evidence, all physical-iPad
checks, and current external-provider behavior/terms remain unverified and
unchecked.

## Slice 4: Professional service foundation

**Outcome:** Establish the paid, secure multi-tenant boundary without coupling
it to guest use.

- [ ] Implement passwordless verified email and Sign in with Apple with safe,
  explicit identity linking and recent reauthentication.
- [ ] Implement workspace/member roles and centralized authorization checks.
- [ ] Add Face ID local unlock/sensitive-action confirmation with passcode
  fallback; never transmit biometric material.
- [ ] Implement subscription state and explicit project/member/storage/archive/
  portal-traffic quotas with warnings and no silent deletion.
- [ ] Configure one disclosed U.S. data region, TLS, managed at-rest encryption,
  least-privilege service identities, secret rotation, audit events, and
  short-lived asset authorization.
- [ ] Add privacy-aware logs, observability, incident controls, and publication
  kill switch.

**Oracle:** The complete role/action matrix passes; each cross-tenant denial has
a positive same-tenant control; email/Apple account-linking takeover cases are
rejected; expired/revoked sessions fail; recent-reauth gates are exercised;
Face ID success/failure/passcode fallback is device-tested; launching and using
guest mode produces zero auth/hosted requests.

**Rollback:** A remote feature flag disables sign-in/upload/publishing while
local packages and AI export remain usable.

## Slice 5: Migration, immutable sync, conflicts, and storage tiers

**Outcome:** Provide recoverable cross-device professional projects without
multi-master data loss.

- [ ] Build explicit guest-project migration with preview, validation, progress,
  retry, and no local deletion.
- [ ] Upload immutable revisions and append only with an expected hosted head.
- [ ] Keep offline edits as immutable local drafts.
- [ ] On stale head, preserve both branches and require compare/rebase/duplicate;
  do not infer or silently merge geometry.
- [ ] Add bounded edit leases for asynchronous one-editor project work.
- [ ] Sync the recoverable working set by default.
- [ ] Keep full RGB/depth/confidence bundles and diagnostics local unless raw
  archive is explicitly enabled after size/privacy review.
- [ ] Make downloads stage, validate, and promote through the existing package
  validation boundary rather than mutating live projects directly.

**Oracle:** Two-client concurrency accepts one expected-head append and rejects
the stale append while preserving both revisions; interrupted/corrupt uploads
leave local and hosted heads unchanged; retry is idempotent; airplane-mode
scan/view/edit/export remains functional; inspection of default uploaded
objects proves raw bundles are absent; recovery on a second device reproduces
the validated working project.

**Rollback:** Stop accepting writes, allow downloads/exports, and retain all
local drafts. Vendor adapters can be replaced behind app-owned contracts.

## Slice 6: Published snapshots, client portal, and professional web

**Outcome:** Deliver no-install interactive room/property presentations through
privacy-minimized immutable snapshots.

- [ ] Build snapshots from a schema allowlist and web-optimized bounded assets.
- [ ] Support room-level and curated property-level portals without cross-room
  spatial claims.
- [ ] Implement interactive floor plan, 3D/orientation views, dimensions,
  quality warnings, original/concept comparison, and static PDF/gallery/ZIP
  fallback.
- [ ] Add 30-day default bearer links, owner-adjustable expiry, optional PIN,
  immediate revocation, access history, and per-link AI-package download.
- [ ] Add constrained logo/business/contact/accent branding with visible
  RoomScanStudio attribution.
- [ ] Add verified accountless comments, Approve, and Request Changes as
  audited feedback records that cannot mutate project truth.
- [ ] Build lightweight professional web flows for properties, concepts,
  feedback, links, roles, billing, history, and downloads.

**Oracle:** Snapshot closure/allowlist tests prove raw frames, world maps,
diagnostics, precise GPS, private notes, and revision history are absent, with
positive controls proving the probe detects injected forbidden fields;
expiration/PIN/revocation and asset-token tests pass under a controlled clock;
feedback authorization cannot call project mutation paths; desktop/mobile
browser screenshots and interaction tests prove floor-plan, 3D, comparison,
fallback, and accessibility behavior.

**Rollback:** Revoke all links and disable new publication independently of
working-project sync; static owner exports remain available.

## Slice 7: Retention, deletion, operations, and release proof

**Outcome:** Make the hosted product operationally honest and release-ready.

- [ ] Implement 30-day trash, permanent-delete bypass, immediate link
  revocation, active-copy purge within 7 days, backup purge within 30 days,
  and cancellation's 30-day read-only export grace period.
- [ ] Expose user-visible state for logical deletion, active purge, and backup
  expiration without promising instantaneous physical erasure.
- [ ] Load-test bounded portal derivatives, storage quotas, signed assets,
  comments, sync conflicts, and deletion jobs.
- [ ] Measure representative room upload/storage/egress costs and set initial
  subscription quotas and warnings from evidence.
- [ ] Update privacy policy, App Store disclosures, threat model, incident
  response, support runbooks, export documentation, release checklist, and
  device/browser compatibility matrix.
- [ ] Run an end-to-end release scenario: guest scan -> quality review -> AI
  package -> external concept -> Concept Set -> workspace migration -> second
  device recovery -> publish -> client feedback -> revoke -> delete/purge.

**Oracle:** Time-controlled lifecycle tests prove every deadline; storage
inventory confirms active and backup purge separately; cancellation preserves
only promised read-only export access; security tests include cross-tenant,
link leakage, malicious upload/archive, and stale-token controls; representative
cost/load reports exist; the end-to-end scenario passes on supported LiDAR
iPhone and iPad plus the supported desktop/mobile browser matrix.

**Rollback:** Cancellation and export grace remain available if new uploads or
publishing are suspended. Purge jobs are idempotent, auditable, and replayable.

## Program completion gate

The program is not complete until all of these claims have direct evidence:

- account-free local capture/export/import remains functional offline;
- old packages load and original revisions remain immutable;
- entry orientation and canonical views are user-confirmed and deterministic;
- weak capture regions are surfaced and preserved in outbound truth;
- AI-ready and Complete packages are independently inspectable;
- imported concepts cannot overwrite source truth;
- stale sync writes preserve both branches;
- cross-tenant reads and mutations fail with positive controls;
- public snapshots contain only allowlisted material;
- link expiry, PIN, revocation, comments, approvals, and access history behave
  as documented;
- deletion and cancellation meet the bounded lifecycle;
- physical LiDAR/device, Share Sheet, Face ID, and browser claims have been
  exercised on their actual platforms.

Passing a build or Simulator suite alone does not satisfy these gates.
