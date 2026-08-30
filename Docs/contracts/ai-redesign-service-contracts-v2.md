# AI redesign professional-service contracts v2

- Status: Slice 5 local implementation contract; no production deployment claim
- Route set: `roomscan-slice5-routes-v1`
- Database migration: forward-only `0008_professional_project_sync.up.sql`
- Supersedes: no prior contract; extends, but does not modify,
  `ai-redesign-service-contracts-v1.md`

## Outcome and boundary

Slice 5 provides recoverable cross-device professional projects without
multi-master data loss. A hosted project has one canonical head and any number
of immutable preserved branches. Every append names the hosted head it expects.
The database may advance that head exactly once; a losing candidate becomes a
downloadable `stale` branch. Geometry is never inferred, merged, or overwritten
by conflict handling.

Guest scan, save, view, edit, export, import, AI package, Concept Set, Share
Sheet, and private CloudKit backup remain local/account-free paths. Nothing in
this contract authorizes publication, a portal, a protected link, browser
delivery, a Slice 7 lifecycle feature, or background upload on local save.

## Compatibility

- `roomscan-slice4-routes-v3` remains an exact, separately exported 19-route
  manifest. Its entrypoint does not register or dispatch the routes below.
- `roomscan-slice5-routes-v1` contains those unchanged 19 routes plus exactly
  10 project-sync routes, for 29 total.
- Existing local package v1/v2, `RoomProjectBackupArchive`, and
  `roomscan-working-project-sync-v1` decoding and validation remain supported.
- Initial migration, append, working-set, and raw attachment use new versioned
  contracts. An initial head is not represented by a sentinel expected head.
- Migration `0008` is additive and forward-only. Fresh install and staged
  `0001` through `0007` upgrade must converge; there is no destructive down
  migration.

## Sealed HTTP surface

All routes use the existing strict JSON parser and transactional authorization
boundary. Unknown fields, unbounded values, caller-selected tenant scope, and
generic route registration fail closed.

| Method and path | Route ID | Authorization and effect |
|---|---|---|
| `POST /projects/migration/allocate` | `project.migration.allocate` | Workspace `project.create`; reserves project/working quota and creates an immutable upload allocation, not a hosted project shell. |
| `POST /projects/revisions/allocate` | `project.revision.allocate` | Workspace `project.revise` resolved against the project; binds both the hosted expected head and local source parent. |
| `POST /projects/uploads/complete` | `project.upload.complete` | Workspace `project.revise` resolved against the upload; durably marks validation pending before a targetless wake. |
| `POST /projects/uploads/status` | `project.upload.status` | Workspace `project.read` resolved against the upload; returns public state only. |
| `POST /projects/recovery/allocate` | `project.recovery.allocate` | Workspace `private.download` resolved against a revision; signs the exact immutable canonical or stale object version. |
| `POST /projects/edit-lease/acquire` | `project.edit-lease.acquire` | Workspace `project.revise`; requests one advisory 900-second holder. |
| `POST /projects/edit-lease/renew` | `project.edit-lease.renew` | Workspace `project.revise`; renews only the matching unexpired token. |
| `POST /projects/edit-lease/release` | `project.edit-lease.release` | Workspace `project.revise`; idempotently releases the matching token. |
| `POST /projects/raw-archive/configure` | `project.raw-archive.configure` | Owner/recent-auth `raw_archive.configure`; records an exact accepted size/privacy review digest. |
| `POST /projects/raw-archive/allocate` | `project.raw-archive.allocate` | Authorized `raw_archive.allocate` resolved against a validated revision; reserves only raw quota. |

Every allocation request includes a stable idempotency key, exact SHA-256 and
byte declaration, and current hosted/quota policy versions. Append additionally
requires non-null `expectedHostedHeadRevisionID` and
`expectedHeadRevisionID`. Signed URLs and headers are transient responses and
must never enter the app journal, database, logs, or status response.

## Public statuses and identifiers

Client-visible identifiers are opaque public project, revision, and upload
IDs. Responses never expose PostgreSQL UUIDs, workspace IDs, S3 keys, provider
versions, queue coordinates, or stored presigned URLs.

Working uploads move through:

```text
allocated -> validationPending -> validating -> canonical | stale | rejected
```

A validated raw attachment ends at `attached` and never changes a project
head. A recovery response names `canonical` or `stale`, the exact working-set
manifest digest, outer archive digest/size, and a fresh transient download URL.
The client derives the complete local descriptor only by inspecting the
digest-bound archive through the Core package-validation boundary.

## Immutable append transaction

Allocation never mutates a head. After the worker validates and immutably
copies the exact provider version, finalization runs in one PostgreSQL
transaction:

1. lock the upload and verify its worker lease, declaration, and provider
   binding;
2. insert the immutable revision/object lineage;
3. compare-and-set `professional_projects.head_revision_id` from the stored
   expected head to the candidate;
4. mark one candidate `canonical` when the row changed, otherwise mark it
   `stale`;
5. finalize or release the exact quota reservation and append a bounded audit
   record.

Initial migration performs the same pattern from no head and creates the
hosted project only after validation. Exact retry returns the same public
allocation/outcome while a changed declaration under the same key is rejected.
Both canonical and stale active object versions remain immutable and
downloadable. No enum, reducer, or app state offers last-writer-wins or an
automatic geometry merge.

## Validation and crash recovery

Upload capabilities expire after 300 seconds and address a server-selected
quarantine key with create-only semantics. The service validates the exact
object version, declared length/checksum/type, bounded ZIP32 STORE structure,
canonical manifests, entry closure/digests, source binding, and raw exclusion.
The common hosted archive ceiling is 67,108,864 bytes.

Completion first commits `validation_pending`, then sends only the fixed
`roomscan-project-validation-wake-v1` message. A scheduled targetless worker
tick first reaps expired incomplete allocations and releases their quota, then
claims the oldest eligible upload with a bounded lease. The message contains no
tenant, project, upload, key, provider version, or digest. Allocation-before-
presign, PUT-before-complete, complete-before-wake, mid-validation,
active-copy-before-CAS, and CAS-before-response are idempotent recovery points.

## Storage tiers

| Tier | Default | Contents | Head effect |
|---|---|---|---|
| Local authoritative package | Always | Full supported local room package and immutable local revisions, including any supported capture evidence | Local truth only |
| Private CloudKit backup | Explicit, separate | Existing private package backup contract | None on hosted state |
| Professional working set | Explicit migration/sync | Raw-redacted package backup, optional redesign/orientation, Concept Sets and attachments, and exact canonical AI-ready provenance required for automatic mapping | Initial CAS or expected-head append |
| Professional raw archive | Default off; owner size/privacy review | Explicit RGB, depth, confidence, diagnostics, or world-map ledger and bytes | Never changes head |

The default working set excludes capture-bundle enumeration, frame RGB, depth,
confidence, diagnostics, world maps, AI artifact payloads, and Complete AI
package manifests whose raw ledger is outside the default schema. Working and
raw objects use separate immutable prefixes, ledger rows, quotas, review
requirements, and audit actions.

## Recovery and conflict semantics

Downloads enter a marker-owned scratch directory, verify outer digest/size,
inspect the strict working-set manifest, validate/extract the package and every
companion, and only then call the existing prepare/commit recovery boundary.
No download mutates a live project directly. A post-package interruption is a
durable, resumable companion-promotion transaction.

Stale-head UI preserves both IDs and offers only:

- read-only compare of validated package/semantic/companion digests;
- explicit rebase by recovering the canonical head as a local copy, followed
  by a user-authored immutable child revision before a later append; or
- explicit duplicate by recovering the stale branch locally, followed by a
  separate migration review.

Recover-as-copy uses only the store-derived promoted-copy binding. It never
fabricates a copy-bound disclosure review or canonical AI package provenance.
Automatic Concept mappings that cannot retain exact provenance downgrade
visibly to manual (or unmatched only when the destination camera is invalid).

## Leases

Edit leases are advisory one-editor coordination for asynchronous work. Server
time sets the exact 900-second bound. Tokens are unguessable, stored only as
digests server-side, retained in process memory on-device, and checked for
acquire/renew/release. Expiry or denial never blocks a local save, destroys a
draft, or replaces the expected-head CAS.

## Authorization and runtime roles

All five new tenant tables enable and force RLS. API mutations derive principal,
workspace membership, role, authorization version, operational flags, quota,
and resource ownership inside the transaction. The credential-backed project-
sync worker role is `LOGIN NOINHERIT`, non-owner, non-superuser, lacks
`BYPASSRLS` and membership edges, and receives only targetless worker reducer
capabilities. Ordinary roles cannot select internal object coordinates.

Infrastructure uses a dedicated encrypted validation queue/DLQ, a targetless
recovery schedule, a bounded worker, private versioned object storage, narrow
prefix/version actions, and exact KMS/Data API/SQS grants. Runtime roles have no
delete, publication, portal, public-bucket, or private-CloudKit capability.

## Logging and privacy

Allowlisted logs may contain bounded event/action/result/correlation values and
pseudonymous public subjects. They must not contain request bodies, filenames,
room bytes, free-form content, precise GPS, tokens, URLs, object keys/versions,
database IDs, workspace IDs, or raw archive contents. Raw opt-in is an outbound
contract review, not authority for the guest scanner to enumerate or upload
capture sidecars.

## Rollback

Rollback sets `hosted_operations_enabled=false` globally and per workspace,
stops the validation event source and recovery schedule, and prevents new
allocations, completions, raw attachments, and leases. Authorized immutable
recovery/download remains available. Migration `0008`, audit state, quarantine
and active versions, canonical/stale revisions, and local journals remain in
place; there is no down migration or runtime deletion. Guest/local work,
exports, private CloudKit backup, and offline drafts remain usable.

## Evidence limits

Local acceptance uses synthetic object/queue providers, disposable PostgreSQL
16, unsigned Simulator/generic builds, mutation controls, and actual Core/app
package fixtures. It is not proof of physical-device background transfer, live
AWS/Data API/S3/SQS/KMS/Lambda/IAM/CloudTrail/alarm behavior, credentials,
deployment, production quota/retention policy, or release approval.
