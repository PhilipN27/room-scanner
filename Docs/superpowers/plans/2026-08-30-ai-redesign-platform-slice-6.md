# RoomScanStudio AI Redesign Platform Slice 6 Implementation Plan

## Formal local closure — 2026-09-20

The operator requested completion and formal closure of Slice 6. This
supersedes the earlier session-only prohibition on a local commit quoted below.
The existing worktree is the implementation under review. Deployment, push,
provider configuration, and Slice 7 remain outside this continuation.

**Status: locally verified and formally closed by the accompanying local
commit.** All 65 task entries and all ten terminal acceptance clauses are
complete. The current report has no failed or incomplete evidence. The
[closure record](../../evidence/2026-09-20-ai-redesign-slice-6-closure.md)
contains the final matrix, exact acceptance command, report digests, reviewed
captures, resolved diagnostic history, and release exclusions.

The closure audit reopened and resolved these local requirements:

1. Task 7's publication and mutation verifier entrypoints were absent. Add
   executable evidence aggregation, negative self-tests, and hosted CI self-test
   wiring; reconcile the task ledger and current product documentation.
2. Property finalization checked secondary room heads without retaining their
   project-row locks through snapshot commit. Acquire every distinct source
   project lock in deterministic order before validating sources. Controlled
   concurrent transactions must prove edit-first rejection, finalizer-first
   edit blocking, and overlapping property finalizations without deadlock.
   Neutralize the new lock guard to prove the regression oracle needs it.
3. The professional browser must organize ordered rooms in properties, including
   version-checked updates; an empty-property-only form is insufficient.
4. Concept review, feedback, downloads, and link creation must support selecting
   among published snapshots and ignore pending/rejected allocations.
5. Add a composed synthetic system-chain oracle using real service handlers,
   database reducers, and publication worker with the Core archive fixture:
   allocation, validation/promotion, link exchange, chunk, feedback, revocation,
   and immediate denial. Fixture-backed browser tests remain complementary.
6. The composed oracle exposed a worker/SQL mismatch: a non-download asset's
   `download_kind` was encoded as an empty string instead of JSON null, causing
   valid publications to retry. Correct the real worker-store serialization;
   retain its failing focused test and composed finalization failure, followed
   by green unit and real-database chain results.
7. The composed property inventory exposed a paging mismatch: the service
   defaulted to 100 properties while the live reducer permits 20. Preserve
   the database bound in the parser, OpenAPI, and browser; room candidates
   remain a separate maximum-100 safe public-ID/title projection.
8. The full native regression matrix exposed an existing Cloud Backup test
   scrolling down from the top of a dismissible sheet, and optional Vision
   analysis waiting inside text recognition. Correct only that test call's
   scroll direction. Bound optional analysis while retaining every mandatory
   manual privacy advisory; prove slow analysis, cancellation, and late-result
   handling through deterministic tests before rerunning both full schemes.
   A subsequent real Vision error also requires the same complete manual
   fallback, proven by an injected-error red/green regression test.
9. Strengthen feedback isolation evidence from head-pointer equality to a
   digest of complete private project/revision/raw-archive/membership rows.
   A real rolled-back project mutation must change the digest. Require all
   twelve assets from the exact two-room fixture in the closure verifier.
10. Require valid bounded screenshot PNGs, contained evidence paths, and exact
    named XCTest attachment bytes. Prove the guards through red/green controls.
    Document that runtime freshness is a post-hoc timestamp sanity check and
    source inventory for observed trusted runs, not a source-execution attestation.
11. Retain bounded app-only evidence after UI failures. Isolated capture tests
    exposed 50-ms simulator touches leaving targets unchanged. Use an explicit
    150-ms duration for the two shared capture-navigation targets and GPS
    request, without retries or weaker assertions. The navigation control
    passed 8/9 repetitions; the remaining GPS touch passed 5/5 after its own
    correction. Require both fresh full schemes and capture the actual visible
    publication error, not only the top of its scroll view.

The service/database composed chain passed on 2026-09-20 with PostgreSQL
16.13, four real runtime roles, the exact two-room Core property fixture,
12 promoted assets, durable encrypted feedback delivery, unchanged private
project heads, and three live post-revocation denials. Its skip-revoke control
failed at the intended assertion (actual 200, expected 503). The subsequent
full native/browser/compatibility matrix and all ten aggregate clauses passed.

Continuation was blocked on local disk headroom: a fresh PostgreSQL cluster
failed with `No space left on device`, and free space subsequently fell below
300 MiB. Disposable outputs from this run were cleaned without touching the
other project's active build. Source changes and raw logs are retained. The
operator approved one verified-inactive Xcode staging-cache cleanup; verification
resumed with 9.2 GiB free. Native focused tests, the browser follow-up matrix,
and the full database suite now pass. Both fresh full iPhone/iPad schemes
passed all 337 tests each without failures or skips; all six current native
publication captures have been visually reviewed and digest-bound.
The unsigned generic build/artifact inspection, full infrastructure suite,
15-stage hosted wrapper, seven-clause Slice 5 compatibility check, final
scaffold check, and terminal Slice 6 aggregate all passed. The task ledger is
closed against the current closure record, not the earlier checkpoint.

Closure requires all ten acceptance clauses below, current component evidence,
full iPhone/iPad schemes, the unsigned compiled-app inspection, reviewed
screenshots, passing database and infrastructure mutation ledgers, reconciled
documentation, and a local commit. Physical-device and live-provider release
gates remain explicit exclusions.

Historical implementation-session instruction; its local-commit prohibition
is superseded by the closure authorization above, not its push/deploy/provider
exclusions:

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task by task,
> and `superpowers:test-driven-development` for each behavior change. The
> operator prohibited Slice 6 commits in this session, so task boundaries are
> recorded in the plan ledger and reviewed from worktree diffs; do not commit,
> push, deploy, provision, or configure external providers.

**Goal:** Deliver no-install interactive room/property presentations through
privacy-minimized immutable snapshots.

**Architecture:** A native publication review constructs a new deterministic
archive from typed, empty public-draft inputs; it never receives a private
project as an encodable snapshot. The archive contains a server-only control
manifest, a separate portal-safe presentation document, and only explicitly
selected bounded derivatives. A new sealed Slice 6 hosted surface allocates the
archive to quarantine, validates actual bytes and exact source/selection/
approval bindings, derives static PDF/gallery ZIP fallbacks, and promotes an
immutable version into the existing private published-derivative bucket.
High-entropy hash-only links exchange into short portal sessions, but every
manifest, asset chunk, download, and feedback request rechecks link generation,
expiry, snapshot, quota, and global/workspace publication state. The portal and
feedback runtime has no project-mutation capability. A dependency-light
TypeScript web package renders the portal and lightweight professional workspace
without introducing capture or spatial editing in the browser.

**Tech Stack:** Swift 5.9 / SwiftUI / UIKit image and PDF rendering /
Foundation deterministic ZIP; Node.js 24 / TypeScript 5.9 / built-in crypto;
PostgreSQL 16 with forced RLS and narrow security-definer reducers; AWS CDK /
API Gateway v2 / Lambda / S3 / SQS / KMS; semantic HTML/CSS/Canvas; XCTest,
Node test runner, PostgreSQL integration tests, Playwright browser tests, and
Python verification scripts.

**Spec:** `Docs/superpowers/specs/2026-08-12-ai-redesign-platform-design.md`

**Starting point:** clean local `main` at
`9d213351b7e734968d82656fb86ca95affaac280`, the locally verified Slice 5
commit. The branch intentionally remains ahead of `origin/main`.

## Evidence-driven plan revision (2026-08-31)

Source inspection after Tasks 1-4 resolved four implementation assumptions
that were not safe to leave implicit:

- The sealed surface has 55 routes: 29 inherited routes, 18 professional or
  publication routes, and one shell plus seven portal routes. Keep one HTTP API
  and use exactly three integrations: the existing private API alias owns the
  inherited routes plus the 17 metadata/mutation professional routes, a new
  portal-delivery alias owns `GET /p`, `/portal/*`, and the single protected
  professional asset-read route, and the existing Stripe alias remains
  webhook-only. Professional and portal routes use service/database capability
  checks rather than the legacy header authorizer. This avoids a second origin
  without giving the portal role a generic professional, project-sync, or
  private-object route.
- `roomscan_api_runtime` receives only the professional publication reducers
  already granted by migration `0009`, quarantine `PutObject`, and a targetless
  validation wake. It remains denied active published reads, private recovery,
  listing, deletion, and portal reducers. `roomscan_portal_runtime` receives
  only live portal reducers and exact active-object-version reads;
  `roomscan_publication_worker` receives only targetless validation and
  quarantine-to-active promotion authority. Slice 5 sync roles remain denied
  every publication prefix and reducer.
- Feedback verification cannot be an optional post-commit callback. Extend the
  still-uncommitted forward-only `0009` migration with a separate encrypted
  feedback-delivery outbox and atomic v3 request reducer. The existing email
  runtime alone claims, validates, completes, cancels, or releases delivery;
  it rechecks link generation, snapshot, expiry, revocation, flags, and the
  kill switch immediately before sending. Portal/API roles receive no SES or
  delivery-provider authority, and the v1 non-durable request reducer is no
  longer executable by a runtime role.
- The 55-route contract intentionally has no public static-asset route. The new web
  package emits one deterministic classic JavaScript bundle, one CSS bundle,
  and a digest manifest. Infrastructure copies those files into the private
  portal Lambda artifact; the service constructs one request-independent `/p`
  document with exact script/style CSP hashes. No CDN, public bucket, runtime
  S3 asset URL, module import, source map, analytics script, or service worker
  is introduced.

These findings refine deployment topology and durability but do not reopen the
approved product scope, frozen Slice 4/5 routes, snapshot formats, or rollback
oracle.

### Native restart and idempotency revision (2026-08-31)

Focused native tests initially passed only within one process. A subsequent
read-only compatibility audit found four recovery assumptions that would allow
duplicate hosted state or fixture-only UI after an app termination:

- A hosted `pua_` can be accepted before native durably records it. Persist a
  separate versioned, public-fact-only publication operation before the first
  network mutation. It contains the exact Codable approval, source/selection/
  approval/archive digests and byte count, bounded room/property routing, and
  stable opaque operation keys; it contains no bearer, PIN, URL, object key or
  version, archive path, private package field, or free-form content. On a
  restart, rebuild the deterministic Core archive only from the same current
  public preparation and stored approval, require every digest to match, and
  reuse the stored allocation key. A changed source or selection fails closed.
- A terminal `snp_` and pending link currently live only in model memory. The
  operation state therefore advances durably through prepared, allocated,
  published, linked/revoked, or rejected phases. Publication completion stores
  `snp_` before clearing allocation recovery. Link creation uses a separately
  persisted non-secret operation key. The existing create-link reducer treats
  an exact semantic retry as the existing link without requiring native to
  reproduce a generated bearer hash or PIN verifier; it still rejects a
  changed snapshot, expiry, PIN-presence, AI policy, or feedback policy. Native
  never persists or receives the raw share capability.
- Property identity cannot be anchored to the mutable first room. Store and
  resolve the local-property-to-`prop_` binding independently of room order,
  and make first creation idempotent with a pre-persisted opaque operation key.
  Existing-property changes continue to use the server's exact version/CAS
  boundary. Removing or reordering the first room must update the same
  `prop_`, and a lost create response must return that same property.
- Native feedback summary is approved scope but was fixture-only. Enrich an
  existing owner-authorized link/status read with a bounded aggregate—count,
  latest action label, and latest recorded time—so no new route is added and
  native receives no comment, display name, email digest, or feedback body.
  The model refreshes this aggregate for the durably recovered link.

The operation journal is additive and separate from Slice 5 project-sync truth.
Literal pre-Slice-6 canonical journal bytes must still decode and re-encode
unchanged, and ordinary Slice 5 sync/recovery must ignore publication sidecar
state. New red/green oracles inject failure immediately after remote allocation,
property creation, snapshot publication, and link creation; a fresh service and
model must converge on one `prop_`, one `pua_`, one `snp_`, and one `lnk_`.
Controls mutate source/selection or semantic link/property input and must fail
closed. Disabling or dismissing PIN UI must erase the in-memory PIN probe.

These findings do not add a route, weaken link secrecy, or change the approved
product surface. They replace the unsafe process-local recovery assumption with
an explicit additive compatibility and completion gate.

### Delivery and browser-boundary revision (2026-08-31)

Database, service, storage, and browser inspection resolved four additional
cross-boundary details before infrastructure or frontend implementation:

- S3 authorizes `HeadObject` through `s3:GetObject`; therefore the private API
  cannot both capture a quarantine version and remain write-only. API completion
  now records and wakes a targetless pending job without a version. After claim,
  the isolated publication worker reads the current quarantine version, binds it
  through the worker-only reducer under the live lease/flag/source/quota checks,
  and then performs exact-version validation. The API receives no quarantine or
  active-object read authority.
- Professional concept/fallback download metadata is not an executable browser
  download. Add one exact `POST /publications/assets/read` route, protected only
  by the professional cookie and served by the portal-delivery integration. Its
  portal-runtime reducers return one active immutable object version/range to the
  delivery service, recheck tenant/membership/session/flags before authorization
  and final emission, and charge `portal_bytes` atomically. It grants no generic
  professional or project mutation capability and does not expose object keys,
  versions, or presigned URLs to the browser.
- A fresh app bearer used to reauthenticate can coexist with one stale
  `roomscan_professional` cookie because the cookie path covers the exchange
  endpoint. Only `professional.session.exchange` may discard exactly that one
  ambient cookie without parsing, hashing, logging, or trusting its value, then
  overwrite both professional cookie paths and return a fresh in-memory CSRF.
  Every other mixed-credential envelope remains denied.
- Mutable link policy is not serialized into immutable `presentation.json`.
  `portal_get_snapshot_v2` returns only live `feedbackEnabled` and
  `aiReadyPackageEnabled` facts with the immutable snapshot metadata. The portal
  may create local typed Blob URLs for protected PNG/JPEG/fallback bytes, so `/p`
  CSP permits `blob:` only in `img-src`; renderer tests must revoke every Blob URL
  on room switch, denial, error, and unmount.

This revision adds one protected route but no new origin, public bucket, CDN,
presigned URL, browser editor, or private-object authority. The final topology is
55 explicit routes across one HTTP API and three integrations: 45 private API,
9 portal delivery, and 1 Stripe webhook.

## Outcome and proof

Slice 6 is complete only when a reviewed exact source revision can produce one
immutable room or curated property presentation whose byte inventory is the
closure of a positive allowlist, a client can open its high-entropy link without
installing the app, and revocation or either publication kill switch denies the
same already-open portal session on its next protected request. The portal must
provide floor plan, orientation/3D, dimensions, warnings, comparison, navigation,
and bounded static fallbacks; property navigation must never imply shared room
coordinates. Verified feedback must append an audited link/snapshot-scoped event
without possessing a project mutation capability. The professional web must
cover approved management flows, while guest/local and private-sync behavior
remain unchanged.

The exact required oracle is:

> “Snapshot closure/allowlist tests prove raw frames, world maps, diagnostics,
> precise GPS, private notes, and revision history are absent, with positive
> controls proving the probe detects injected forbidden fields;
> expiration/PIN/revocation and asset-token tests pass under a controlled clock;
> feedback authorization cannot call project mutation paths; desktop/mobile
> browser screenshots and interaction tests prove floor-plan, 3D, comparison,
> fallback, and accessibility behavior.”

## Scope

- New strict, additive room-publication v2 and property-publication v1
  contracts, canonical fixtures, empty positive-allowlist builder, selection
  digest, source-binding digest, approval binding, archive closure, and bounded
  asset ledger.
- Native iOS publication review from a room detail or professional workspace:
  exact source revision, disclosure status, selected images/concepts, warnings,
  branding, property room order, fallback selection, link expiry/PIN/download
  policy, publication status, revoke, and feedback summary.
- A forward-only PostgreSQL `0009` migration for immutable publications/assets,
  property composition, mutable link controls, portal sessions, PIN throttle
  state, feedback verification, immutable feedback, privacy-conscious access
  history, and publication-worker state.
- A new sealed `roomscan-slice6-routes-v1` service contract and entrypoint that
  preserves the exact Slice 4 19-route and Slice 5 29-route manifests.
- Validate-stage-promote publication, a dedicated targetless worker, separately
  scoped published storage access, server-derived PDF/gallery ZIP fallbacks,
  exact AI-ready-package validation, and revocation-aware chunk delivery.
- High-entropy link creation, 30-day default expiry, owner-authorized adjustment,
  optional six-digit PIN with memory-hard verifier and controlled cooldown,
  immediate revocation for subsequent requests, per-link AI-package enablement,
  and access history without raw IP, raw user agent, link token, URL, email, or
  content bytes.
- Verified accountless Comment, Approve, and Request Changes records, append-only
  and scoped to one link generation and immutable snapshot.
- A responsive first-party client portal and lightweight professional web for
  properties, concepts, feedback, links, roles, billing, access history, and
  downloads.
- Infrastructure, CI, mutation controls, browser/native screenshots,
  accessibility checks, full regression matrix, docs, and evidence.

## Exclusions

- Slice 7 trash, permanent delete, physical purge, backup expiry, cancellation
  grace, production pricing, load testing, release operations, or retention
  cleanup jobs.
- Custom domains, full white-labeling, removal of RoomScanStudio attribution,
  third-party portal analytics, service workers on protected pages, public S3
  objects, or a reusable direct object/presigned URL.
- Browser capture, browser semantic/spatial editing, real-time collaboration,
  multi-room transforms, shared coordinate epochs, alignment, connectivity,
  adjacency, continuous reconstruction, or survey/construction claims.
- Hosted model inference, changes to immutable capture truth, changes to private
  CloudKit backup, automatic publication on local save, or guest launch-time
  hosted initialization.
- Real credentials, customer data, email/AWS/CDN/domain configuration,
  deployment, purchasing, external-account mutation, or a production release.

## Product decisions fixed for this implementation

The approved design leaves bounded implementation details to this slice. The
following conservative choices avoid reopening product scope:

- A link defaults to exactly 30 days, can be set from one hour through 365 days,
  and is denied when server time is equal to or later than `expires_at`.
  Publication link create/update/revoke follows the existing role/action matrix:
  Owner/Admin with recent authentication, or Editor with recent authentication
  and the workspace editor-publishing flag. “Owner-adjustable” means the
  authorized snapshot owner/workspace control, not an accountless visitor.
- Only the current canonical immutable hosted revision may start publication.
  A later project edit does not mutate an existing snapshot, but it invalidates
  any not-yet-finalized approval and requires a new publication for new content.
- Disabling either publication flag advances a grant epoch. Re-enabling does not
  resurrect old portal sessions; a link must be explicitly reset or reissued.
- Immediate revocation means that after the revoke transaction commits, every
  new protected authorization fails, including requests using an established
  session and later asset chunks. Bytes already delivered cannot be withdrawn;
  a request authorized before the commit may finish its current bounded chunk.
- PINs are optional six digits. Five wrong attempts in fifteen minutes produce
  a fifteen-minute per-link-generation cooldown; responses stay uniform. Reset
  rotates link generation, PIN salt/verifier, and all portal sessions.
- Feedback stores an HMAC-pseudonymous verified-email digest and a display label
  of “Verified client”; raw email is used only by the existing bounded delivery
  lane and is not exposed in access history. Verification expires in fifteen
  minutes and is single-use for one link/snapshot purpose.
- Access history stores an hourly timestamp bucket, action/outcome, coarse
  client-family enum, and keyed network-risk digest with a 90-day logical
  expiry. Physical retention cleanup remains Slice 7 and is not claimed here.
- Portal-safe raster assets are strict PNG or JPEG, geometry is bounded canonical
  JSON, and active SVG/HTML are never publication asset formats. A service-owned
  renderer derives a passive PDF and deterministic gallery ZIP from validated
  records; AI-ready ZIP remains separately bound and validated.
- Protected files are delivered in at most 4 MiB opaque chunks. Every chunk
  reauthorizes and accounts exact delivered bytes against `portal_bytes`, so a
  large fallback or AI-ready download neither bypasses immediate revocation nor
  depends on a reusable object URL.
- Local/browser compatibility target for executable evidence is current Safari
  and the installed Playwright Chromium when available. Unsupported Canvas/
  interactive behavior must expose the same approved gallery/PDF/ZIP fallback.

## Affected trust boundaries and invariants

| Boundary | Slice 6 responsibility | Non-negotiable invariant |
|---|---|---|
| Local package -> native publication review | Select exact revision, public facts, derivatives, concepts, warnings, branding, downloads, and approve disclosure | The snapshot builder accepts only a new public draft. It never serializes a project/package and never subtracts forbidden fields. |
| Native app -> hosted quarantine | Upload one digest/size-bound deterministic publication archive | Quarantine is not active/public; server revalidates actual bytes and exact source/selection/approval bindings. |
| Publication worker -> published object store | Validate, derive passive fallbacks, write immutable versioned objects, finalize ledger | Dedicated role/prefix; no portal access to private sync/raw storage; no overwrite or partial publication. |
| Professional client -> workspace API | Manage properties, publications, links, roles, billing views, feedback, history, downloads | Canonical principal/membership/role/recent auth/flags are server-derived in one transaction. |
| Bearer link -> portal session | Exchange fragment secret, optional PIN, short session | Raw link/PIN is not persisted or logged; GET shell never consumes authority; session is not sufficient for assets after revoke. |
| Portal delivery -> object store | Resolve opaque public asset ID to exact private object/version and stream one chunk | DB/flag/link/quota authorization occurs for every request; no S3 key or reusable URL leaves the service. |
| Verified visitor -> feedback | Append one link/snapshot-scoped immutable event | Capability and SQL role cannot mutate geometry, concepts, revisions, membership, project head, or private truth. |
| Snapshot -> browser DOM/Canvas | Render typed public records and validated passive bytes | No raw HTML; free text uses text nodes; strict CSP/Trusted Types policy; no third-party protected-page script or analytics. |
| Property presentation -> room presentation | Navigate an ordered set of independent rooms | No transform, shared origin, alignment, connection, adjacency, or reconstruction field exists; switching rooms resets orientation state. |
| Publication controls -> guest/private workflows | Kill public creation/auth/feedback/download/assets | Guest/local, private sync, private recovery/export, and CloudKit remain usable and do not consult publication state. |

## Frozen additive contracts

Do not change `roomscan-portal-snapshot-v1`, the Slice 4 v3 route export, the
Slice 5 v1 route export, or migrations `0001` through `0008`. Add:

- `roomscan-published-room-snapshot-v2`: internal control manifest plus
  portal-safe presentation for one exact source revision.
- `roomscan-published-property-snapshot-v1`: ordered composition of independently
  bound room presentations without any cross-room spatial field.
- `roomscan-publication-archive-v1`: deterministic ZIP closure containing
  `publication-manifest.json`, `presentation.json`, selected raster/geometry/
  texture/concept assets, optional exact AI-ready package, and no owner-generated
  PDF/gallery ZIP. The service derives those fallbacks after validation.
- `roomscan-slice6-routes-v1`: the unchanged first 29 routes plus the 26 exact
  routes below.
- `0009_publication_portal.up.sql`: forward-only schema and reducers.

The portal-safe `presentation.json` contains no private project/revision IDs,
source digests, raw object keys, link state, email, or audit data. The internal
control manifest contains exact server-resolvable source bindings and approval,
but is not an authorized portal asset.

The 26 Slice 6 routes bring the additive manifest to 55 routes:

```text
POST /professional/session/exchange                 professional.session.exchange
POST /professional/session/logout                   professional.session.logout
POST /professional/properties/list                  professional.properties.list
POST /professional/properties/upsert                professional.properties.upsert
POST /professional/concepts/list                    professional.concepts.list
POST /professional/members/list                     professional.members.list
POST /publications/snapshots/allocate                publication.snapshot.allocate
POST /publications/snapshots/complete                publication.snapshot.complete
POST /publications/snapshots/status                  publication.snapshot.status
POST /publications/snapshots/list                    publication.snapshot.list
POST /publications/links/create                      publication.link.create
POST /publications/links/update                      publication.link.update
POST /publications/links/revoke                      publication.link.revoke
POST /publications/links/list                        publication.link.list
POST /publications/feedback/list                     publication.feedback.list
POST /publications/access-history/list               publication.access-history.list
POST /publications/downloads/list                    publication.downloads.list
POST /publications/assets/read                       publication.asset.read
GET  /p                                              portal.shell.get
POST /portal/link/exchange                           portal.link.exchange
POST /portal/pin/verify                              portal.pin.verify
POST /portal/snapshot                                portal.snapshot.get
POST /portal/asset                                   portal.asset.read
POST /portal/feedback/verification/request           portal.feedback.verification.request
POST /portal/feedback/verification/consume           portal.feedback.verification.consume
POST /portal/feedback                                portal.feedback.create
```

`professional.session.exchange` accepts one currently valid app/session bearer,
creates an eight-hour opaque `Secure; HttpOnly; SameSite=Strict` browser session,
and returns a separate CSRF value held only in page memory. Professional mutation
requests require the cookie plus CSRF header. Portal cookies are distinct,
`SameSite=Strict`, link-generation-bound, and never authorize professional APIs.

## Frontend/service/schema compatibility strategy

- Core keeps all v1 fixtures byte-identical and uses a version/kind registry for
  the new room-v2/property-v1 documents. Swift and TypeScript share golden
  canonical fixtures and digest expectations.
- iOS adds publication types and views without changing guest environment
  construction. Hosted transport is injected only after entering authenticated
  professional UI. Existing AI package, Concept Set, orientation, quality,
  local export, and Slice 5 sync models remain the source seams.
- The service exports a separate Slice 6 entrypoint. Its matcher delegates exact
  legacy requests to the unchanged Slice 4/5 entrypoints and owns only the 26
  appended routes. OpenAPI v3 is additive and explicit for portal responses.
- The database fresh-install path applies `0001`-`0009`; staged `0001`-`0008`
  upgrade converges without editing old checksums. All tenant control tables use
  forced RLS. Immutable snapshot/asset/feedback tables grant no runtime
  `UPDATE`/`DELETE`; mutable link/session/throttle state lives separately.
- The existing API role gains only professional publication reducers,
  quarantine write, and a targetless validation wake; it gains no active
  published read. New publication-worker and portal-delivery roles are
  separately credentialed. Portal SQL capabilities expose only
  link/snapshot/asset/access/feedback reducers, while every project-sync role
  remains denied publication storage and reducers.
- Web is a new `HostedService/web` package using semantic HTML, TypeScript, CSS,
  Canvas, and first-party assets. It consumes a strict public presentation DTO,
  not the internal publication manifest, and provides graceful non-Canvas and
  reduced-motion fallbacks. Its deterministic CSS/JavaScript output is embedded
  in the private portal-delivery Lambda and pinned by exact CSP hashes; no new
  public/static route is added.
- Private CloudKit, Slice 5 immutable sync/recovery, local packages, and the
  frozen Slice 4/5 contract remain behaviorally unchanged.

## Ordered tasks

### Task 1: Core publication contracts, empty builder, and byte closure

**Files:**

- Create: `RoomScanCore/Sources/RoomScanCore/RoomPublishedSnapshotContracts.swift`
- Create: `RoomScanCore/Sources/RoomScanCore/RoomPublicationArchive.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/RoomRedesignContracts.swift`
- Test: `RoomScanCore/Tests/RoomScanCoreTests/RoomPublishedSnapshotTests.swift`
- Test fixtures: `RoomScanCore/Tests/RoomScanCoreTests/Fixtures/Publication/`

- [x] Add compile-red tests for the missing v2/v1 models and empty builder.
- [x] Define strict typed public draft, control manifest, presentation DTO,
  source bindings, selection ledger, approval, semantic accent, branding,
  independent rooms, assets, comparisons, warnings, dimensions, orientation,
  and explicit downloads. No draft initializer accepts `RoomProject`, package,
  raw archive, revision history, notes, GPS, or generic `[String: Any]`.
- [x] Bind approval to the canonical exact-source-binding digest and exact
  selection/manifest digest. Prove any revision, room order, selected artifact,
  concept, brand, warning, or download change invalidates it.
- [x] Build a deterministic archive from an owned empty stage and require exact
  entry closure, portable ASCII paths, case-fold collision rejection, per-entry
  digest/size/type, bounded totals, and immutable output digest.
- [x] Strictly accept only canonical JSON, metadata-free PNG/JPEG, bounded public
  geometry/texture, approved concept rasters, and separately validated AI-ready
  ZIP. Reject SVG/HTML, polyglots, renamed Complete/raw/private archives,
  unledgered entries, traversal, symlinks, case/Unicode aliases, bombs, trailing
  data, EXIF GPS, private XMP, and auxiliary payloads.
- [x] Reject caller-authored PDF/gallery ZIP bytes. Core carries only explicit
  fallback policy; the service derives bounded passive files after it repeats
  byte validation in Task 4.
- [x] Add every forbidden field/artifact injection plus safe controls. Add a
  positive detector control for each Core-owned negative family while preserving
  every portal-v1 fixture. Task 4 owns TypeScript parity for the shared golden
  canonical bytes and digests.
- [x] Run focused Core tests red then green, followed by full `swift test`.

### Task 2: Native publication review and professional entry points

**Files:**

- Create: `RoomScanStudio/Features/Publication/RoomPublicationReviewView.swift`
- Create: `RoomScanStudio/Features/Publication/RoomPublicationModel.swift`
- Create: `RoomScanStudio/Infrastructure/Publication/RoomPublicationService.swift`
- Create: `RoomScanStudio/Infrastructure/Publication/RoomPublicationTransport.swift`
- Modify: `RoomScanStudio/Features/RoomLibrary/RoomDetailView.swift`
- Modify: `RoomScanStudio/Features/Professional/ProfessionalProjectSyncView.swift`
- Modify: `RoomScanStudio/App/RoomScanStudioApp.swift`
- Modify: `RoomScanStudio.xcodeproj/project.pbxproj`
- Test: `RoomScanStudio/RoomScanStudioTests/RoomPublicationTests.swift`
- UI test: `RoomScanStudio/RoomScanStudioUITests/RoomPublicationUITests.swift`

- [x] Add failing model/UI tests for exact revision display, disclosure review,
  invalidation on selection/source change, room/property mode, explicit
  independent-room disclaimer, branding constraints, fallback preview, 30-day
  default, expiry/PIN/download controls, status, revoke, and feedback summary.
- [x] Reuse orientation/quality/Concept Set/image sanitizer/export seams to
  create public drafts; never give the builder the live project/package URL.
- [x] Make publication available only after professional sign-in and recent
  local sensitive-action confirmation. Preserve visible authoritative-original
  and concept-is-reference wording.
- [x] Keep the professional transport lazy/default-off. Prove guest launch and
  scan/save/view/edit/export/import/AI/share construct no publication or hosted
  client and remain usable when publication is killed.
- [x] Persist a non-secret publication operation before allocation and prove a
  fresh process reuses the exact property/allocation/snapshot/link identities
  after injected lost responses or journal-write failures. Keep the sidecar
  separate from Slice 5 sync truth, rebuild only deterministic public archives,
  and fail closed when current source, selection, approval, or archive identity
  differs.
- [x] Make property creation idempotent independently of the first room, retain
  update CAS, make semantic link-create retries independent of unrecoverable
  bearer/PIN verifier bytes, and fetch the required native feedback aggregate
  through an existing owner-authorized read without comment or identity fields.
- [x] Load literal Slice 5 canonical journal bytes with no Slice 6 keys, preserve
  byte-compatible re-encoding and recovery, and clear the in-memory PIN on
  disable/dismiss.
- [x] Add deterministic DEBUG fixtures for room, property, pending approval,
  warning, revoked, and failure states; accessibility identifiers, Dynamic Type,
  reduce motion, VoiceOver labels, iPhone/iPad adaptive layouts, and screenshots.
- [x] Run focused app tests/UI tests red then green and inspect the generic built
  artifact for the new contracts without adding them to guest bootstrap wiring.

### Task 3: PostgreSQL 16 publication, link, portal, and feedback authority

**Files:**

- Create: `HostedService/db/migrations/0009_publication_portal.up.sql`
- Create: `HostedService/db/test/integration-0009-publication.mjs`
- Create: `HostedService/db/test/integration-0009-portal-security.mjs`
- Create: `HostedService/db/test/mutations-0009-publication.mjs`
- Modify: `HostedService/db/package.json`
- Modify: `HostedService/db/test/staged-upgrade.mjs`
- Modify migration manifest/checksum sources under `HostedService/infra/`

- [x] Start with missing-table/function red tests. Add tenant properties and
  order-only room membership; publication allocations/jobs; immutable snapshot,
  source, and asset rows; link controls/generations; portal/professional
  sessions; PIN attempt state; feedback verification; immutable feedback; and
  append-only access events.
- [x] Add `roomscan_publication_worker` and `roomscan_portal_runtime` as
  `LOGIN NOINHERIT` roles without role edges, superuser, `BYPASSRLS`, private
  project access, or generic mutation grants. Revoke PUBLIC and use fixed-search-
  path security-definer reducers only where accountless scope must be resolved.
- [x] Force RLS on every tenant table. Prove same-tenant allowed and cross-tenant
  denied for property/publication/link/feedback/history paths, including pooled
  connection context clearing and opaque-ID substitution.
- [x] Allocate against current canonical source bindings, exact digests,
  approval, role/recent-auth/editor-publishing policy, quota policy, and current
  hosted/publication flag versions. Finalization rechecks all versions and fails
  closed if the kill switch changed during work.
- [x] Implement server-time link issuance/update/revoke, default/bounds,
  generation rotation, expiry equality denial, PIN cooldown/reset, hash-only
  secret state, short sessions, and disable/re-enable epoch invalidation.
- [x] Make each snapshot/asset-chunk/download/feedback reducer reauthorize the
  current link generation, exact snapshot, expiry, publication flags, and
  per-link entitlements. Account authoritative delivered bytes atomically to
  the existing `portal_bytes` quota boundary.
- [x] Make feedback append-only and enforce capability plus SQL proof that the
  portal role cannot call project/revision/concept/member mutation. Record
  privacy-minimized audit/access fields only.
- [x] Add a separate forced-RLS encrypted feedback-delivery outbox and an
  atomic `portal_request_feedback_verification_v3` reducer. Grant request
  insertion only through the portal reducer and claim/validate/complete/
  cancel/release only to `roomscan_email_delivery_runtime`; revoke runtime
  execution of the non-durable v1 request reducer. Recheck the exact live
  session/link generation/snapshot/expiry/flags/kill switch at claim,
  validation, and immediately before provider delivery.
- [x] Add `publication_upsert_property_v2` with a server-HMAC'd, tenant-and-
  principal-scoped create idempotency digest. Generate `prop_` only on the
  first insert; an exact same-key/title/ordered-room retry returns `existing`
  without a version bump, while changed input conflicts without mutation.
  Keep v1 defined but remove its production runtime grant, and preserve the
  existing positive-version CAS boundary for updates.
- [x] Make link-create replay compare only recoverable semantic intent—exact
  snapshot, effective expiry, PIN-presence, AI policy, and feedback policy—
  while never returning or requiring regeneration of the original bearer or
  PIN verifier. Enrich the existing owner-authorized link list with only the
  bounded feedback count/latest-action/latest-time aggregate required by iOS.
- [x] Add controlled-clock concurrency tests for revoke commit barriers, active
  sessions, asset chunks, kill during publication, link/PIN reset, verification
  replay, idempotency, and private recovery remaining available.
- [x] Neutralize source-binding, approval, revoke, flag, PIN throttle, RLS, and
  feedback-isolation guards one at a time; retain red outputs, restore, rerun.

### Task 4: Hosted publication validator, worker, routes, and capability services

**Files:**

- Create: `HostedService/service/src/publication/contracts.ts`
- Create: `HostedService/service/src/publication/archive-validator.ts`
- Create: `HostedService/service/src/publication/static-renderer.ts`
- Create: `HostedService/service/src/publication/publication-worker.ts`
- Create: `HostedService/service/src/publication/link-service.ts`
- Create: `HostedService/service/src/publication/feedback-service.ts`
- Create: `HostedService/service/src/publication/index.ts`
- Create: published object/provider and capability adapters under
  `HostedService/service/src/adapters/` and `src/persistence/`
- Modify: route manifest, OpenAPI, handler factory, composition, exports, and
  package scripts under `HostedService/service/src/`
- Tests: new `publication-*.test.ts`, `portal-*.test.ts`, and route/OpenAPI tests
  under `HostedService/service/test/`
- Cross-runtime fixtures: `HostedService/fixtures/publication/`

- [x] Add route/contract tests that fail while only the sealed 19/29 manifests
  exist. Add the exact 55-route manifest and a distinct Slice 6 entrypoint while
  proving legacy export identity and behavior.
- [x] Implement strict duplicate-key/canonical JSON and ZIP parsing by factoring
  reusable transport primitives without weakening the Slice 5 validator. Parse
  actual image/geometry/archive bytes; do not trust extension or media type.
  Prove Swift/TypeScript parity against shared golden canonical bytes/digests.
- [x] Derive bounded passive PDF and deterministic gallery ZIP from only the
  revalidated public record/ledger. Reject active PDF actions/attachments and
  require exact ZIP closure; never pass through caller-authored fallbacks.
- [x] Implement allocate -> immutable quarantine -> targetless complete/wake ->
  claim -> worker capture and lease-bound exact-version bind -> validate ->
  derive passive fallbacks -> immutable promote -> finalize. DB
  is authoritative, queue messages are fixed wakes, provider work is post-commit,
  retries are idempotent, and no partial object is portal-authorized.
- [x] Use built-in `scrypt` with bounded parameters for PIN verification. Keep
  raw bearer/PIN/email/comment/snapshot bytes out of structured logs, error
  messages, analytics, crash payloads, and audit subjects.
- [x] Separate professional cookie/CSRF, portal-session, and feedback-verification
  capabilities. The feedback service constructor must have no project mutation
  dependency and its repository interface must be unassignable to one.
- [x] Make feedback delivery required and durable: seal the email/code payload
  into the atomic database outbox transaction, wake the existing targetless
  email lane, and never acknowledge a request that cannot be durably queued.
  Keep plaintext email/code only in bounded worker memory and out of logs,
  audit, queues, crash payloads, and access history.
- [x] Route property create/update through `publication_upsert_property_v2`:
  require a validated create idempotency key, HMAC it with a distinct domain,
  stop client-side `prop_` generation, accept `created`/`existing`/`updated`,
  and keep the 55-route surface unchanged. Route link-create semantic replay
  and the privacy-bounded native feedback aggregate through the revised
  reducers without exposing comments, display names, email, bearer, or PIN.
- [x] Correct the reviewed implementation defects before accepting the service:
  room snapshots return an empty property-room list without calling the
  property reducer; archive hashing admits bounded multi-megabyte reads;
  professional sessions cover both `/professional` and `/publications` and
  logout expires both; OpenAPI models `RoomScan-Link` as an API-key header;
  a fresh fragment may replace stale portal cookies without parsing or trusting
  them; a fresh app bearer may replace exactly one stale professional cookie
  only at session exchange; and the inert fragment `CustomEvent` shell is removed.
- [x] Add the professional-cookie protected asset route to the portal-delivery
  root only. Reuse the exact bounded range reader, call the professional
  authorize/finalize reducers around the exact active-version read, recheck kill
  and session revocation before emission, charge `portal_bytes`, and never emit
  an object key/version or presigned URL. Keep PrivateApi quarantine-write-only.
- [x] Serve shell HTML with restrictive CSP, Trusted Types where supported,
  `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, no token echo, no
  third party, and history-fragment scrubbing. Serve protected bytes only as
  exact opaque chunks after live authorization; active formats use attachment.
- [x] Cover correct PIN, brute force, distributed/cooldown/reset/expiry,
  non-logging, pre/post-revoke active session and asset, wrong snapshot/link,
  kill switch, access quota, feedback replay/cross-link/capability, and token
  canaries in logs/referrers/history/analytics/crash collectors under a
  controlled clock.
- [x] Run focused red/green tests, guard-neutralization tests, then hosted
  typecheck/build/full service suite above the 304-test Slice 5 baseline.

### Task 5: Private published storage and infrastructure wiring

**Files:**

- Create publication worker/delivery roots and AWS adapters under
  `HostedService/infra/src/functions/` and `src/aws/`
- Modify: `HostedService/infra/src/stacks/platform-stack.ts`
- Modify: `HostedService/infra/src/policy/template-policy.ts`
- Modify migration manifest/operator expectations under `HostedService/infra/`
- Tests: publication provider/root/policy/mutation tests under
  `HostedService/infra/test/`

- [x] Add failing synth-policy tests for missing dedicated publication queue,
  DLQ, worker, database credentials, and revocation-aware delivery root. The
  final local topology is 12 Lambda assets, 10 runtime database roles/secrets,
  five queue/DLQ pairs, 55 explicit routes, and three HTTP API integrations.
- [x] Reuse the existing private `PublishedDerivativeBucket` only with new
  `server/published/quarantine/v1/` and `server/published/active/v1/`
  namespaces, exact immutable version reads, encryption, no public access, and
  no runtime deletion. The API receives quarantine writes only; every sync role
  remains denied and only portal delivery receives exact active-version reads.
- [x] Give the builder only publication quarantine/active, queue, KMS, and worker
  reducer access. Give delivery only exact active version reads plus portal
  reducers. Neither role can read project-sync/raw/private-active/backup data.
- [x] Wire one existing HTTP API to exactly three integrations: frozen/private
  API for inherited plus 17 professional/publication routes, portal delivery
  for `/p`, seven `/portal/*` routes, and the single professional protected-
  asset route, and the unchanged Stripe webhook lane. Assert exact integration
  counts of 45 private API, 9 portal delivery, and 1 Stripe route.
  Do not add a proxy route, second public origin, or legacy authorizer to a
  cookie-capability route.
- [x] Wire fixed wake messages, one-record worker delivery, bounded concurrency,
  timeout/visibility, recovery schedule, DLQ/alarm, log redaction, migration
  role secret, and Slice 6 routes without changing old route roots.
- [x] Prove synthesized resources have no public bucket policy, CDN bypass,
  identity pool, generic presign, private bucket-key response, or cross-boundary
  IAM wildcard. Add mutations for every new policy assertion and restore them.
- [x] Run infra typecheck, synth/policy, mutation, and full local suites above
  the 110-test Slice 5 baseline.

### Task 6: Client portal and professional web

**Files:**

- Create: `HostedService/web/package.json`, lockfile, TypeScript configs, build
  script, and Playwright config
- Create shared DTO/API/security/rendering modules under
  `HostedService/web/src/shared/`
- Create portal shell/application/CSS under `HostedService/web/src/portal/`
- Create professional shell/application/CSS under
  `HostedService/web/src/professional/`
- Create unit/integration tests under `HostedService/web/test/`
- Create browser interaction/a11y tests under `HostedService/web/e2e/`
- Create synthetic safe/malicious fixtures under `HostedService/web/fixtures/`

- [x] Add failing unit/browser tests for fragment scrub/exchange, PIN state,
  room/property navigation, independent coordinate reset, floor plan,
  Canvas orientation/3D, dimensions, warnings/disclaimers, original/concept
  slider, approved download/fallback behavior, feedback verification/actions,
  professional navigation, and error/loading/empty/revoked/killed states.
- [x] Build a distinctive field-notebook/blueprint interface using the existing
  warm paper, ink, blueprint teal, warning amber, serif heading, rounded body,
  monospaced-fact language. Use semantic tokens, 4pt spacing, one primary action,
  no gradient/neon/glass/generic dashboard grid, and always-visible
  RoomScanStudio attribution.
- [x] Render the floor plan from typed semantic JSON and the orientation/3D view
  from bounded geometry on Canvas; never interpret uploaded SVG/HTML. Room
  changes create a new renderer state rather than carrying camera coordinates.
- [x] Implement keyboard/touch comparison control, responsive navigation,
  44px targets, visible focus, skip link, live status/error regions, meaningful
  labels/alt text, 200% zoom, high contrast, reduced motion, and Canvas fallback.
- [x] Render every free-form field with text nodes/attributes, never `innerHTML`.
  Exercise stored-injection canaries in title, brief, request, concept, brand,
  contact, comment, filename, metadata, and feedback fields; prove none execute
  or exfiltrate while benign Unicode renders.
- [x] Build professional flows for properties, concepts, feedback, links, roles,
  billing, history, and downloads. Fetch concept/fallback bytes only through the
  professional-cookie protected chunk route; never use object URLs from the
  service, presigns, or private storage keys. Do not expose capture, geometry mutation,
  semantic editing, or live project truth mutation.
- [x] Run unit, integration, production build, desktop/mobile Playwright
  interaction/a11y tests, and capture reviewed desktop/mobile screenshots for
  interactive and forced-fallback modes.
- [x] Emit deterministic classic JavaScript/CSS plus a digest manifest for
  inline service delivery. Fail the build on external imports/URLs, source
  maps, unsafe DOM sinks, inline handlers, dynamic code, service workers, or
  third-party requests; pin the exact bytes in `/p` CSP and prove the shell is
  request-independent.
- [x] Consume live portal AI/feedback capability flags, permit typed local Blob
  URLs only for validated protected image/fallback bytes, and revoke every Blob
  URL on room change, denial, error, and unmount. Prove CSP contains `blob:` only
  in `img-src` and no external network origin.

### Task 7: End-to-end verification, mutation evidence, docs, and rollback proof

**Files:**

- Create: `Scripts/verify_slice6_publication.py`
- Create: `Scripts/verify_slice6_mutation_controls.py`
- Create corresponding Python self-tests
- Modify: `.github/workflows/ci.yml`
- Create: `Docs/contracts/ai-redesign-service-contracts-v3.md`
- Create: `Docs/evidence/2026-08-30-ai-redesign-slice-6-verification.md`
- Modify: `Docs/architecture.md`, `Docs/privacy.md`, threat model, runbook,
  README, known limitations, and master build plan

- [x] Begin with verifier self-tests that fail while scripts/clauses/artifacts
  are absent. Require real Core/service/DB/infra/web/app sources and reject
  skipped clauses, stale fixture digests, wrong Postgres, count regressions,
  missing screenshots, or a non-cleanly restored mutation.
- [x] Add one end-to-end synthetic publication from exact native source approval
  through service validation, immutable promotion, link exchange, portal render,
  asset chunks, feedback, revoke, and immediate post-revoke denial.
- [x] Inject every forbidden field/artifact and every link/content token canary;
  prove the probe first detects a positive control and then proves the released
  snapshot/log/history/referrer/analytics/crash inventories are clean.
- [x] Safely neutralize each new closure, source/selection approval, byte media,
  revocation, asset, flag, PIN, RLS, feedback-capability, CSP/escaping, and IAM
  guard; run its focused test red, restore source, and rerun green. Preserve a
  machine-readable mutation ledger.
- [x] Run the complete Swift, iPhone, iPad, unsigned generic build/artifact,
  service, PostgreSQL 16, infra, web, browser, Slice 4, Slice 5, and Python
  verifier matrix. Counts must exceed 304 Swift package, 282 unique tests on
  each iPhone/iPad scheme, 304 service, 110 infra, and 46 Python tests.
- [x] Review desktop/mobile portal screenshots and iPhone/iPad native screenshots
  against the approved design and accessibility requirements, then run final
  frontend audit/polish checks.
- [x] Document exact commands/results, red/green evidence, mutation restoration,
  privacy/security/compatibility, rollback, and unavailable physical device,
  real browser/provider/email/AWS/CDN/domain/deployment gates without implying
  local evidence is live-provider evidence.

## Exact completion oracle

Run from repository root with synthetic/local provider configuration and no
external account changes:

The commands below describe component collection. The publication command
without `--aggregate` is **not** the terminal completion oracle. Final closure
must use `--aggregate` with real full-suite logs, current iPhone/iPad result
bundles, the generic compiled app, reviewed capture provenance, and passing
Slice 4/5 plus mutation reports, as bound in the current closure record.
Use exact dedicated simulator IDs on a shared development host and serialize
the native runs; add `-collect-test-diagnostics never` to avoid unbounded
automatic diagnostics. Preserve explicit test screenshot attachments.

```sh
git status --short --branch
git rev-parse HEAD

swift test --package-path . \
  --scratch-path /private/tmp/roomscan-slice6-core \
  --disable-sandbox --no-parallel

npm --prefix HostedService run typecheck
npm --prefix HostedService run build
npm --prefix HostedService test

npm --prefix HostedService/db test

npm --prefix HostedService/infra run typecheck
npm --prefix HostedService/infra run test:local
npm --prefix HostedService/infra run test:mutations
npm --prefix HostedService/infra run verify

npm --prefix HostedService/web run typecheck
npm --prefix HostedService/web test
npm --prefix HostedService/web run build
npm --prefix HostedService/web run test:e2e

python3 -B -m unittest discover -s Scripts -p 'test_*.py'
python3 -B Scripts/verify_slice4_hosted.py \
  --artifacts-dir .artifacts/slice4-hosted-slice6-regression
python3 -B Scripts/verify_slice5_mutation_controls.py \
  --artifacts-dir .artifacts/slice5-mutations-slice6-regression
python3 -B Scripts/verify_slice5_sync.py \
  --artifacts-dir .artifacts/slice5-sync-slice6-regression
python3 -B Scripts/verify_slice6_mutation_controls.py \
  --artifacts-dir .artifacts/slice6-mutations
python3 -B Scripts/verify_slice6_publication.py \
  --artifacts-dir .artifacts/slice6-publication

xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/roomscan-slice6-iphone-derived \
  -resultBundlePath /private/tmp/roomscan-slice6-iphone.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test

xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /private/tmp/roomscan-slice6-ipad-derived \
  -resultBundlePath /private/tmp/roomscan-slice6-ipad.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test

xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/roomscan-slice6-generic-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build

python3 -B Scripts/inspect_slice5_ios_artifact.py \
  --app /private/tmp/roomscan-slice6-generic-derived/Build/Products/Debug-iphoneos/RoomScanStudio.app \
  --output .artifacts/slice6-publication/ios-slice5-regression.json \
  --require-marker roomscan-professional-working-set-v1 \
  --require-marker preserveBranchesRequireUserResolution \
  --forbid-marker lastWriterWins
```

The Slice 6 verifier passes only if its machine-readable report proves:

1. A new snapshot is created from the public-draft allowlist and exact archive
   closure. Every raw frame/depth/confidence/world-map/diagnostic/GPS/private-
   note/history field and smuggling class is absent or rejected, and an injected
   positive control proves each detector reaches real source/bytes.
2. Approval equals the exact immutable source-binding and exact selection/
   manifest digests. Source, room order, asset, concept, branding, warning, or
   download changes fail until a new review is approved.
3. A room and ordered property portal render floor plan, orientation/3D,
   dimensions, warnings, disclaimer, original/concept comparison, navigation,
   and bounded gallery/PDF/ZIP fallback. The property contract and renderer have
   no shared-coordinate/alignment/connectivity/reconstruction field or state.
4. A 30-day link works before expiry, fails at equality, handles owner-adjusted
   bounds, correct PIN, brute force/cooldown/reset, and never logs raw bearer or
   PIN. Per-link AI download is enforced.
5. One active portal session and valid asset chunk succeed, then both fail on
   the first post-revoke request. Every subsequent manifest, asset, range/chunk,
   PDF, ZIP, AI download, and feedback request fails. Short URL lifetime is not
   counted as the revocation control.
6. Same-tenant publication/link/feedback controls succeed; every cross-tenant,
   wrong-link, wrong-snapshot, stale-generation, and forged capability fails.
   Forced RLS and narrow SQL/IAM roles prevent portal/feedback access to private
   project/sync/raw/membership mutation.
7. Verified Comment, Approve, and Request Changes append immutable audited
   feedback for one link/snapshot. Capability-level and SQL-level tests prove no
   call path to geometry, concept, revision, membership, or project mutation;
   before/after private truth digests remain identical.
8. Activating either publication kill switch during concurrent publication and
   an active session prevents finalization and denies link auth, feedback,
   downloads, and every protected asset. Re-enable does not revive stale
   sessions. Private sync/recovery/export and guest/local workflows stay green.
9. Browser injection canaries in every rendered free-form field do not execute,
   exfiltrate, enter referrers/history/analytics/crash payloads, or become HTML.
   Desktop/mobile interaction, screenshot, keyboard, focus, zoom, contrast,
   reduced-motion, and accessibility checks pass in interactive and fallback
   modes.
10. Legacy portal-v1 fixtures, exact Slice 4/5 manifests, immutable sync/
    recovery, CloudKit separation, generic unsigned iOS delivery, full iPhone/
    iPad schemes, PostgreSQL 16 migration/RLS, service/infra suites, and Slice
    4/5 verification oracles remain green above their stated baselines.

## Rollback point

Before enabling any Slice 6 publication, `publication_enabled` remains false
globally and per workspace. Rollback sets both scopes false, which advances the
publication epoch and immediately denies new snapshot allocation/finalization,
link exchange, existing portal sessions, feedback, downloads, and every
protected asset chunk. Stop the publication worker event source and recovery
schedule after the flag barrier. Existing immutable snapshot/object/link/audit
rows and migration `0009` remain for forensics and later recovery; there is no
destructive down migration or runtime object deletion. Owners retain local
static exports. Slice 5 private sync/recovery, private CloudKit backup, and all
guest/local workflows remain usable. Re-enabling requires explicit link reset or
reissue and never silently revives a pre-disable portal session.

## External gates not claimed by local completion

- Physical LiDAR iPhone/iPad, Face ID/passcode, real Share Sheet, and physical
  accessibility/touch behavior.
- Live email delivery/scanner behavior and real Sign in with Apple/browser
  authentication provider behavior.
- Live AWS S3 version pinning/KMS/streaming, SQS/Lambda/Data API contention,
  CloudTrail/alarms/IAM propagation, CDN/cache behavior, or deployed immediate
  revocation.
- Real Safari/Chrome/Firefox/Android/iOS browser-provider compatibility when a
  corresponding locally runnable browser is unavailable.
- Domain, certificate, CDN, deployment, production quota/pricing/retention,
  load, release, or Slice 7 lifecycle evidence.
