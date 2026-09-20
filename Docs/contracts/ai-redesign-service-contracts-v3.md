# AI redesign hosted-service contract v3 — published snapshots and portals

- Date: 2026-08-31
- Status: Slice 6 local implementation contract; no production deployment claim
- Supersedes for new publication clients: none; this contract is additive to
  `ai-redesign-service-contracts-v1.md` and `ai-redesign-service-contracts-v2.md`
- Route-set identity: `roomscan-slice6-routes-v1`
- Database migration: forward-only `0009_publication_portal.up.sql`

## Outcome

Slice 6 delivers no-install room and curated-property presentations from new,
immutable, privacy-minimized snapshots. A published snapshot is never a private
project with fields removed. Native Core starts with an empty typed public draft,
copies only enumerated fields and bounded derivatives, binds approval to exact
source and selection identities, then produces a deterministic archive. The
hosted worker independently validates the actual archive bytes before promoting
immutable versioned objects.

This contract does not authorize browser capture or spatial editing, shared
multi-room coordinates, real-time collaboration, public object storage, custom
domains, complete white-labeling, or Slice 7 deletion/retention behavior.

## Versioned snapshot closure

The only accepted publication schema identities are:

- `roomscan-published-room-snapshot-v2`
- `roomscan-published-property-snapshot-v1`
- `roomscan-publication-selection-manifest-v1`
- `roomscan-publication-archive-v1`

The presentation allowlist contains only web geometry/textures, semantic room
layout, selected sanitized raster images, floor plan, dimensions, bounded
quality warnings, approved original/concept comparisons, constrained branding,
explicit download options, and the mandatory RoomScanStudio attribution and
disclaimers. A property is an ordered collection of independently published
room-local facts. It has no coordinate-space, transform, alignment,
connectivity, adjacency, topology, doorway, or combined-reconstruction field.

Raw RGB/depth/confidence, diagnostics, world maps, precise GPS, private notes,
revision history, private archive material, and unapproved work have no schema
slot. Unknown keys, unknown archive entries, ledger mismatches, renamed private
archives, active SVG/HTML, polyglots, EXIF GPS, private XMP, auxiliary/trailing
payloads, and unledgered ZIP entries fail closed.

Every approval binds all of the following exact immutable values:

- ordered hosted source project/revision identities and source manifests;
- canonical source-bindings SHA-256;
- canonical selection-manifest SHA-256;
- disclosure review identity and approval SHA-256;
- archive manifest SHA-256, archive SHA-256, and byte count.

A changed source head, room order, selected derivative, concept, branding,
download option, link policy intent, or disclosure decision requires a new
approval. Existing snapshots remain immutable historical presentations; they
do not follow later private edits.

## Sealed HTTP surface

The v3 export is exactly 55 routes. Its first 29 route objects are the
reference-identical frozen Slice 5 manifest. Slice 6 appends 26 routes:

- professional session exchange/logout and bounded properties, concepts, and
  member reads;
- publication allocate/complete/status/list, link create/update/revoke/list,
  feedback/history/download lists, and protected professional asset read;
- request-independent `GET /p` plus link exchange, PIN verification, snapshot,
  protected asset, feedback verification request/consume, and feedback append.

The private API integration owns 45 routes, PortalDelivery owns 9, and Stripe
owns 1. PortalDelivery has no generic private API or project mutation delegate.
`POST /publications/assets/read` is browser-cookie-only; the native app bearer
cannot use it. Portal credentials cannot be normalized as native app bearers.

All mutable professional browser requests require the session cookie and CSRF.
Role/action, recent-authentication, tenant, hosted-operation, workspace, quota,
and publication flags are derived server-side. Native publication JSON uses
the existing app bearer and signed archive upload carries no Authorization,
Cookie, or CSRF header.

## Publication and storage state machine

Native durably records only bounded public recovery facts in the additive
`roomscan-publication-operation-journal-root-v1` sidecar. It never records a raw
link secret, PIN, share URL, signed object URL, object key/version, private path,
archive bytes, or free-form client content.

The hosted flow is:

1. Allocate under the exact source/selection/approval identities and reserve
   publication quota.
2. Upload a deterministic archive to an immutable quarantine namespace.
3. API completion records a targetless pending validation; it cannot read the
   quarantine object.
4. The publication worker claims the job, binds the current exact quarantine
   version, validates archive closure/media/AI-package identities, derives the
   bounded PDF/gallery fallback, writes new immutable active versions, and
   atomically finalizes the asset ledger.
5. Link policy may change or revoke without mutating snapshot bytes.

The published bucket is private and versioned. Resource policy denies deletion,
overwriting an existing active identity, wrong namespaces, insecure transport,
and principals outside their exact API/worker/portal lane. Neither portal nor
professional browser receives an object key, version ID, or presigned URL.

## Links, sessions, PINs, and protected bytes

A link secret is 32 random bytes encoded as a 43-character base64url fragment.
Only its keyed hash is stored. The browser captures it once, replaces history
with `/p` before exchange, consumes it once, and never sends it in a referrer,
analytics, crash, or log payload. The public shell is request-independent and
uses `no-store`, `Referrer-Policy: no-referrer`, `nosniff`, exact build-asset CSP
hashes, Trusted Types, and no third-party scripts.

Default expiry is 30 days; authorized owners may choose one hour through 365
days. Optional PINs are exactly six ASCII digits and use the database-supplied
bounded memory-hard verifier policy. Five wrong attempts in fifteen minutes
produce a uniform fifteen-minute cooldown. Reset rotates the link generation,
PIN material, and all sessions.

Every snapshot, feedback, download, and protected asset request rechecks the
current link generation, expiry, revocation, tenant, snapshot, global/workspace
publication flags, and portal quota. Protected delivery is limited to a 4 MiB
exact range. Bytes remain private until a second database finalizer runs after
the exact object-version read; it repeats live authorization and accounting.
Therefore an established session or previously authorized asset is denied on
its next request immediately after revoke or kill-switch commit.

## Feedback and access history

Accountless Comment, Approve, and Request Changes are immutable audited records
for one link generation and snapshot. Verification is single-use, expires after
15 minutes, and stores a keyed email pseudonym rather than raw email. The
encrypted delivery outbox is written atomically; the email runtime repeats live
link/flag validation immediately before its provider port.

The feedback capability exposes no method or SQL execute grant for project,
revision, concept, geometry, membership, or project-head mutation. Professional
views receive bounded feedback records; native recovery receives only count,
latest action label, and latest time.

Access history stores an hourly bucket, bounded action/outcome, coarse client
family, and keyed network-risk digest. It stores no raw IP, user agent, URL,
link/session/PIN token, email, comment, archive path, object identity, or
content bytes. Ninety-day logical expiry is modeled; physical cleanup remains
Slice 7 and is not claimed.

## Frontend compatibility

The portal accepts only the typed room-v2/property-v1 presentation documents
and live capability flags. Free-form content is inserted as text, never raw
HTML. Asset Blob URLs are typed, scoped, and revoked on room change, denial,
error, and unmount. If Canvas/interactive rendering is unavailable, the same
approved static floor plan, gallery, PDF, and ZIP remain available.

The professional browser is deliberately lightweight. It supports properties,
concepts, feedback, links, roles, billing status, access history, and bounded
downloads. Capture, full semantic/spatial editing, and project-truth mutation
remain native iOS responsibilities.

Property organization is a draft curation workflow, not publication approval.
`POST /professional/properties/list` defaults to, and permits at most, 20
properties per page. It returns `items` plus a separately bounded
`roomCandidates` inventory (at most 100 current synced rooms, each containing
only `projectID` and a title of at most 180 characters). The inventory uses
the same professional credential and workspace authorization; it does not
require a room to have been published or previously added to a property.
It exposes no geometry, revision content, or storage capability. The existing
upsert route creates an ordered room list with a stable create idempotency key,
or updates it with `propertyID` and `expectedVersion`. Publication still
requires a separate exact-source disclosure review and finalizer head check.
Published-snapshot selection scopes concept review, feedback, downloads, and
new links; pending and rejected allocations are not selectable publications.

## Compatibility and rollback

- Slice 4's 19 routes and Slice 5's 29 routes remain sealed and ordered.
- Migration `0009` is additive and forward-only. Existing migrations, stored
  project revisions, immutable sync/recovery, and local package formats are not
  rewritten.
- Guest scan/save/view/edit/export/import remains account-free and offline.
  Private CloudKit backup is separate from hosted professional sync and
  publication.
- Operational rollback is `publication_enabled=false` globally or per
  workspace. It denies snapshot creation, link exchange/authorization,
  feedback, downloads, and every protected asset request, including active
  sessions. Private sync/export/recovery, CloudKit, guest, and local workflows
  remain available.

No destructive down migration is part of rollback. No production environment,
provider, email, CDN, domain, credential, or customer data is configured by
this contract.
