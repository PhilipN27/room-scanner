# RoomScanStudio AI Redesign Platform Design

Date: 2026-08-12
Status: approved implementation baseline

## Authority and supersession

This specification records the product decisions approved after the original
RoomScanStudio master plan. It deliberately revises the former prohibition on
accounts, servers, hosted portals, public links, and property grouping, but only
within the boundaries below. If this specification conflicts with the legacy
scope in `ROOMSCANSTUDIO_MASTER_BUILD_PLAN.md`, this specification controls.

The existing package-first, append-only, local-first architecture remains the
foundation. Professional hosting is a new delivery and collaboration boundary;
it must not become the source of capture truth or a dependency of guest use.

## Outcome

RoomScanStudio will become an orientation-aware spatial capture and redesign
handoff system. It will describe a real room more faithfully than ordinary
photo uploads, let a user instruct an external AI to stage, renovate, or
reimagine it, preserve the original scan as immutable evidence, import concepts
non-destructively, and optionally deliver projects through a professional
workspace and interactive client portal.

The v1 accuracy promise is:

> Spatially faithful concept staging.

RoomScanStudio guarantees the quality and honesty of its exported room
description. It does not guarantee that an external model follows every
constraint. Renovate and Reimagine results are explicitly conceptual.

## Repository baseline

The repository currently provides a native Swift/iOS app with:

- RoomPlan semantic capture and normalized structural/object data;
- ARKit/LiDAR capture bundles, posed RGB keyframes, depth and confidence maps,
  scene mesh evidence, and photoreal colored-mesh processing;
- append-only one-room packages with immutable revision lineage;
- semantic, mesh, splat, orbit, and first-person viewing;
- semantic editing, local exports, Share Sheet delivery, and private opt-in
  CloudKit backup/recovery.

The current private CloudKit backup path is not a professional sync or sharing
platform. It must remain isolated unless separately retired through an explicit
migration plan.

## Product principles

1. Core capture, save, viewing, editing, AI export, import, and Share Sheet use
   work without an account and without a network connection.
2. The room package and immutable local revisions remain authoritative capture
   truth. Hosted delivery never rewrites that truth.
3. RoomScanStudio pays no model-inference costs in the guaranteed v1 workflow.
4. The guaranteed AI path is a provider-neutral AI Room Package shared to
   ChatGPT, Claude, Grok, or another provider using the customer's own account.
5. Direct insertion into a provider chat is optional and may be offered only
   when an officially supported integration has been verified.
6. Every uncertainty, omission, unavailable artifact, and quality weakness is
   represented honestly in machine-readable and human-readable output.
7. Hosted storage, bandwidth, privacy, retention, deletion, and operations are
   paid-product responsibilities even though inference is user-paid.

## Users and entry paths

### Try a room

Guest mode requires no account. Local scan, save, view, edit, export, AI share,
concept import, and comparison remain fully functional. A guest may later sign
in and explicitly migrate a local project into a professional workspace.

### Professional workspace

Only authenticated professional workspace members may upload working projects
or publish portals. A paid subscription funds hosted storage, portal bandwidth,
backups, collaboration, access history, and retention guarantees.

Professional roles are:

- Owner: workspace ownership, billing, deletion, security, and all project
  operations.
- Admin: member, project, publishing, and operational management except
  ownership transfer or other owner-only actions.
- Editor: upload, revise, import concepts, comment, and publish when permitted.
- Viewer: inspect and download private workspace material without editing.

Collaboration is asynchronous. One editor holds a bounded edit lease for a
room project at a time. Comments and approvals are supported; live co-editing
and automatic conflict merging are not.

## Orientation and spatial truth

Every room that is shared with AI or published must have a user-confirmed
canonical entry and inward-facing direction. RoomScanStudio may suggest the
entry from the scan-start pose and detected door or opening, but the user must
confirm or correct it. A room without a clear entrance uses a user-selected
reference wall and facing direction.

The normalized orientation record includes:

- entry position and inward direction in the room coordinate system;
- source (`suggested`, `confirmed`, or `manual`) and confidence;
- canonical room axes and top-down orientation;
- entry-facing, wall-facing, corner, orbit, and perspective camera definitions;
- language-ready relationships such as left/right from entry;
- the revision and coordinate-space epoch to which it applies.

Orientation drives floor plans, canonical images, circulation guidance,
provider prompts, portal navigation, and cross-view comparison.

## Capture quality contract

Saving uses a recommended quality gate with an explicit Save Anyway override.
Quality dimensions remain separate:

- visual sharpness;
- spatial/visual coverage;
- AR tracking;
- semantic identification confidence.

The scan flow provides live, location-specific guidance and an affected-region
map when supported by evidence. The finish review includes a structured quality
summary, missing/weak coverage, and the reason for each warning. Saving anyway
preserves the warnings in the revision and every derived AI package. No quality
score is represented as survey accuracy.

Sharpness guidance must build on the existing frame analysis without moving
expensive image processing into the capture hot path. Real-device evidence is
required before claiming that location-specific blur guidance works.

## Semantic presentation

Walls, doors, windows, openings, floors, ceilings, fixed objects, movable
objects, and unknown objects receive distinct semantic roles and accessible
viewer colors. Color is not the only distinction; legends, labels, selection,
and accessibility descriptions retain the category.

## Redesign intent

The user supplies a required free-form design request and may add structured
constraints for purpose, style, budget, household needs, accessibility,
circulation, materials, colors, reference images, and desired objects.
RoomScanStudio compiles the request without replacing or weakening the user's
words.

Each request chooses one scope:

- **Stage** (default): preserve the room shell while changing furniture,
  finishes, lighting concepts, and decor.
- **Renovate**: the user identifies fixed or structural features that may be
  changed.
- **Reimagine**: anything may change; the original room remains visible as
  factual reference.

Per-feature constraints are machine-readable as `preserve`, `mayChange`, or
`requestedChange`. Redesign permissions are stored separately from captured
geometry and never mutate it.

## AI Room Package

### Profiles

**AI-ready** is the default profile. It is bounded and optimized for consumer
AI upload limits and comprehension. **Complete** is an explicit advanced
profile for capable providers, expert workflows, and a future RoomScanStudio
local AI service.

Both profiles have a versioned manifest that records every included, excluded,
skipped, unavailable, or failed artifact with stable reason codes.

### Required information

The package contains, when available and appropriate to its profile:

- normalized semantic room graph;
- walls, floor, ceiling, doors, windows, openings, objects, and entry
  orientation;
- dimensions, units, coordinate-system definition, and accuracy disclaimer;
- top-down/floor-plan orientation and canonical camera definitions;
- rendered entry, wall, corner, orbit, and perspective views;
- selected sharp reference images with camera poses;
- materials and textures;
- separate quality/confidence dimensions and missing-coverage report;
- a concise human-readable room brief;
- the original free-form request and structured redesign constraints;
- provider-tailored instruction files that preserve the same underlying
  provider-neutral truth;
- provenance and checksums sufficient to identify the source project,
  immutable revision, schema version, and selected evidence.

The Complete profile may additionally include larger image sets, meshes,
textures, depth/confidence evidence, and diagnostic artifacts. Precise GPS is
excluded by default from both profiles.

### Outbound privacy review

Every AI share and portal publication requires a disclosure review. The user
sees selected images and metadata and may exclude or replace them. Advisory
detection should flag likely people, faces, family photos, documents, screens,
addresses, precise location, and reflective-surface disclosures. It must never
claim perfect detection or redaction.

External providers receive data under their own privacy and account terms; the
app must say so before handoff.

## Concept Sets

Every imported redesign is a non-destructive Concept Set bound to one immutable
room revision. It records:

- redesign scope and user request;
- provider when disclosed by the user;
- source AI-package/schema version;
- creation/import timestamps;
- image and attachment provenance;
- canonical-view mapping or explicit manual/unmatched status;
- comments, approval state, and archive state.

Concepts may be compared with the original, approved, commented on, replaced,
or archived. They never overwrite captured geometry, measurements, evidence,
or revision history.

## Property grouping

A lightweight property container groups independent room projects. Room-level
and curated property-level portals are supported. V1 makes no claim that rooms
share a coordinate system, align physically, or have inferred doorway
connectivity. Continuous whole-property reconstruction is deferred.

## Hosted project architecture

### Canonical shared lineage

After migration, the hosted workspace owns the canonical *shared revision
lineage*, while devices continue to author immutable local package revisions.
An upload appends only when its expected base is still the hosted head. Offline
work remains a local draft. A stale upload preserves both branches and requires
explicit comparison, rebase, or duplicate; it never silently merges or drops a
revision.

This hosted coordination role does not make the service authoritative for raw
capture truth: the uploaded immutable revision and its validated provenance are
the unit of sync.

### Storage tiers

Default sync stores a recoverable working project: normalized semantics,
dimensions, revision lineage, selected posed photos, usable meshes/textures,
concepts, comments, and the assets required for supported cross-device work,
publishing, and export.

High-volume RGB/depth/confidence frame sequences, diagnostic capture bundles,
and similar raw evidence remain local unless the owner explicitly enables raw
capture archiving. Quotas and estimated transfer size are shown before upload.

### Identity and device security

Professional authentication uses verified email magic links plus Sign in with
Apple. Identities are merged only after explicit verification. Sensitive and
destructive actions require recent reauthentication. Optional passkeys or MFA
may be added without changing identity ownership.

On supported iOS devices, Face ID provides local app unlock and sensitive-action
reauthentication with device-passcode fallback. Biometric data never leaves the
device and is never represented as server identity proof by itself.

### Encryption and tenancy

V1 uses strong encryption in transit and managed encryption at rest, strict
tenant isolation, least-privilege service permissions, signed short-lived
asset access, audited exceptional operator access, and incident procedures.
It makes no end-to-end encryption, zero-knowledge, or operator-inaccessibility
claim. Client-encrypted raw archives remain a future option.

### Region and commercial model

V1 launches in one disclosed U.S. data region. Architecture is region-aware,
but no non-U.S. residency guarantee is made. Guest/local use is free.
Professional hosting requires a subscription with transparent limits for
active projects, members, working storage, raw archives, and portal traffic.
The product warns before limits and never silently degrades or deletes data.

Exact providers, prices, and quota values are implementation decisions that
require measured cost and capability evidence.

## Publication and portals

### Snapshot boundary

Client portals receive separate, immutable, privacy-minimized published
snapshots rather than access to a live project. Snapshot construction uses an
explicit allowlist and may include web-optimized geometry/textures, semantic
layout, selected images, floor plan, dimensions, quality warnings, approved
concept comparisons, branding, and enabled downloads.

Raw RGB/depth/confidence frames, world maps, diagnostic bundles, full revision
history, private notes, precise GPS, and unapproved working material remain
private. AI Room Package download is controlled per link.

### Client links

Clients need no account. A portal link is a revocable bearer capability with:

- 30-day default expiration, adjustable by the owner;
- optional PIN protection;
- immediate revocation;
- owner-visible, privacy-conscious access history;
- short-lived authorization for underlying assets.

Accountless feedback is optional per link. After lightweight email
verification, a client may comment, Approve, or Request Changes. Those actions
are audited and cannot alter room truth, geometry, concepts, or revisions.

### Portal experience

The no-install browser portal supports interactive floor-plan and 3D/orientation
inspection, original-versus-concept comparison, dimensions and disclaimers,
quality warnings, room/property navigation, and approved downloads. A bounded
static gallery/PDF/ZIP fallback remains available when interactive rendering is
unsupported.

Workspace branding includes logo, business name, contact details, and a
constrained semantic accent color with visible RoomScanStudio attribution.
Custom domains and complete white-labeling are deferred.

### Professional web workspace

The browser workspace supports property organization, concept review,
comments/approvals, link management, roles, billing, access history, and
downloads. Capture and full semantic/spatial editing remain native to iOS in
v1.

## Location privacy

Precise GPS is captured only by explicit permission and remains private working
project data. It is excluded from published snapshots and AI Room Packages by
default. A professional may deliberately publish a separately reviewed display
address or approximate location.

## Retention and deletion

- Deleted projects enter 30-day recoverable trash.
- Delete Permanently bypasses trash.
- Portal links revoke immediately when their snapshot/project is deleted.
- Active hosted copies are purged within 7 days of permanent deletion.
- Backup replicas are purged within 30 days.
- Workspace cancellation provides a 30-day read-only export grace period,
  after which projects enter the same bounded deletion lifecycle.
- Nothing is retained indefinitely by default.

The implementation must distinguish logical deletion, active-data purge, and
backup expiration and must expose truthful status for each.

## V1 guarantees and non-guarantees

V1 targets:

- a recognizable same room in Stage concepts;
- preserved wall, door, and window placement when marked `preserve`;
- plausible furniture scale and circulation;
- consistent design direction across canonical views;
- honest export of dimensions, orientation, evidence, and uncertainty.

V1 does not promise:

- survey-grade measurements or guaranteed furniture fit;
- construction-ready plans or code-compliant structural work;
- perfectly identical generated furniture across views;
- external-model compliance;
- accuracy of generated Renovate/Reimagine structural changes;
- continuous multi-room reconstruction;
- full browser editing, real-time collaboration, or simultaneous multi-master
  mutation;
- first-party hosted or local inference.

## Failure and rollback posture

- Hosted features are independently feature-gated. Disabling them must leave
  guest/local workflows intact.
- Schema evolution is additive and versioned. Migration uses validate-stage-
  promote behavior and never rewrites original revisions in place.
- Published snapshots are allowlisted from validated source data rather than
  produced by subtracting known-sensitive files from a complete package.
- Sync uses conditional expected-head writes and preserved branches.
- The service has a publication kill switch that can stop new publishing and
  revoke links without affecting local projects.
- Interactive portals use bounded derivatives and progressive loading, with a
  static fallback.
- Vendor-specific adapters sit behind app-owned contracts so a hosting vendor,
  identity provider, payment processor, or AI-provider hint can be replaced.

## Assumptions requiring implementation evidence

- The hosted vendor and database/object-storage topology are not selected.
- Subscription prices and quotas require measured storage/bandwidth costs.
- Provider upload limits and direct-chat capabilities are volatile and must be
  verified from official provider documentation before release.
- Automated privacy detection is advisory.
- Physical RoomPlan, ARKit, LiDAR, blur localization, and Share Sheet behavior
  require supported-device validation.
- App Store privacy declarations, policies, incident procedures, and deletion
  wording require operator and legal review; repository tests cannot establish
  legal compliance.

This plan received a structured same-model self-review. It received no
cross-model pass.
