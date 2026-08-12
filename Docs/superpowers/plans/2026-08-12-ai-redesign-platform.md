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

- [ ] Re-read the master plan, approved design, current architecture/privacy/
  export/backup docs, repository instructions, and relevant memory.
- [ ] Inventory current local package, export, backup, capture, and viewer
  contracts; identify additive versus migration-requiring fields.
- [ ] Verify installed Apple SDK APIs used by entry orientation, RoomPlan
  categories, AR camera poses, depth/confidence, Face ID, and Share Sheet.
- [ ] Write an architecture decision record comparing at least two viable
  U.S.-region service stacks against conditional writes, row/tenant isolation,
  signed object access, encryption, lifecycle deletion, auditability, web
  deployment, email/Apple identity, subscription billing, local development,
  and measured operating cost.
- [ ] Define versioned schemas for local extensions, hosted API resources,
  AI-ready/Complete packages, working-project sync, and portal snapshots.
- [ ] Produce a threat model covering cross-tenant access, bearer links, PINs,
  session theft, upload validation, malicious archives, operator access,
  deletion, and publication kill switch.

**Oracle:** Schema fixtures validate and reject malformed/cross-version input;
an ADR records evidence and rejected alternatives; a clean baseline build/test
matrix passes before product code changes; no server dependency appears on the
guest launch/capture/export path.

**Rollback:** No production data or network path is introduced in this slice.

## Slice 1: Spatial truth, orientation, semantics, and property containers

**Outcome:** Add the local data needed by all later packages and portals.

- [ ] Add additive, versioned models for confirmed entry position/direction,
  canonical axes/cameras, orientation source/confidence, property containers,
  redesign permissions, hybrid briefs, and Concept Set provenance.
- [ ] Preserve backward decoding of every current package and fixture.
- [ ] Add an orientation review step that suggests but requires confirmation
  before AI export/publishing; support manual reference-wall fallback.
- [ ] Generate deterministic entry, wall, corner, orbit, perspective, and
  top-down camera definitions from normalized room coordinates.
- [ ] Give walls, doors, windows, openings, floor, ceiling, fixed, movable, and
  unknown elements distinct semantic tokens, legends, and accessibility text.
- [ ] Add lightweight property grouping without any cross-room transform or
  doorway inference.

**Oracle:** Old fixtures load unchanged; new schemas round-trip deterministically;
invalid/non-finite orientation transforms fail closed; original revision bytes
remain unchanged; unit fixtures prove canonical cameras; iPhone/iPad screenshots
prove semantic distinctions in light/dark and accessible presentation.

**Guard proof:** Temporarily neutralize the orientation-required export guard;
the focused negative test must fail, then pass after restoration.

**Rollback:** New fields are optional for legacy viewing; disable new review/UI
without altering stored legacy projects.

## Slice 2: Live and finish-time quality guidance

**Outcome:** Produce honest location-specific scan coaching and a persistent
four-dimension quality report.

- [ ] Define bounded quality records for sharpness, coverage, tracking, and
  semantic identification, each with evidence, affected regions, confidence,
  and stable reason codes.
- [ ] Reuse existing posed keyframes and frame sharpness analysis to aggregate
  visual quality into room-space regions after bounded per-frame work.
- [ ] Add lightweight live coaching without decoding or scoring full images on
  the capture hot path.
- [ ] Add coverage overlays and specific revisit guidance.
- [ ] Add a recommended Finish gate, structured review summary, and explicit
  Save Anyway action that records weak regions in the immutable revision.
- [ ] Export the same report into AI packages and published snapshots.

**Oracle:** Deterministic sharp, blurred, uncovered, low-confidence, and
tracking-limited fixtures exercise each independent warning; controls prove
the detector reaches the unsafe paths; Save Anyway persists exact warning
provenance; supported LiDAR iPhone/iPad sessions deliberately capture good and
bad controls and visually confirm region mapping.

**Rollback:** Quality coaching is advisory and feature-gated; capture/save
continues with the existing general guidance if localized analysis fails.

## Slice 3: AI Room Package, disclosure review, and Concept Sets

**Outcome:** Complete the guaranteed user-funded AI workflow end to end.

- [ ] Implement canonical provider-neutral package schemas and manifests.
- [ ] Build AI-ready selection from semantic truth, orientation, quality,
  canonical views, and bounded sharp posed images.
- [ ] Build Complete as an explicit superset with additional available meshes,
  textures, images, depth/confidence, and diagnostics.
- [ ] Encode required free-form intent, optional structured constraints, Stage/
  Renovate/Reimagine, and per-feature `preserve`/`mayChange`/`requestedChange`.
- [ ] Generate provider-tailored instruction files without changing underlying
  truth; treat verified direct-chat insertion as optional adapters.
- [ ] Add mandatory outbound privacy review, advisory sensitive-content flags,
  image exclusion/replacement, and default precise-GPS exclusion.
- [ ] Deliver through the existing iOS Share Sheet with owned lease cleanup.
- [ ] Import loose or packaged outputs as revision-bound Concept Sets; map to
  canonical views automatically only when confidence is sufficient and allow
  manual mapping otherwise.
- [ ] Add original-versus-concept comparison and concept archive/delete flows.

**Oracle:** Golden AI-ready and Complete fixtures pass schema, manifest,
checksum, and archive-closure tests; every requested artifact has an included/
excluded/skipped/failed record; GPS/raw-default negative tests include positive
controls; package extraction succeeds in independent tooling; device Share
Sheet completion/cancel/recovery is exercised; concept import/delete cannot
change semantic geometry, measurements, or source revision digests.

**Rollback:** Package versions coexist with the legacy head export. Concepts
are additive attachments and can be hidden without altering source rooms.

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
