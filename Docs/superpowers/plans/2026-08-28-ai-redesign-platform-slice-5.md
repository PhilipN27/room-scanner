# RoomScanStudio AI Redesign Platform Slice 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The operator prohibited commits for this session, so task boundaries are recorded in the plan ledger and reviewed from worktree diffs; do not create commits.

**Goal:** Provide recoverable cross-device professional projects without multi-master data loss.

**Architecture:** A professional working-set archive wraps a raw-redacted, fully recoverable room-package backup plus revision-bound redesign/orientation, Concept Set, and exact canonical AI-ready Room Package provenance companions needed for automatic Concept mappings. Hosted writes use durable quarantine allocations, targetless asynchronous validation, immutable active-object promotion, and one PostgreSQL expected-head compare-and-swap that records either a canonical revision or a preserved stale branch. Raw capture evidence is a separately reviewed and separately stored attachment; private CloudKit backup and every guest workflow remain independent.

**Tech Stack:** Swift 5.9 / SwiftUI / Foundation deterministic ZIP, Node.js 24 / TypeScript 5.9, PostgreSQL 16 with forced RLS and security-definer reducers, AWS CDK / API Gateway v2 / Lambda / S3 / SQS / KMS, XCTest, Node test runner, and Python verification scripts.

**Spec:** `Docs/superpowers/specs/2026-08-12-ai-redesign-platform-design.md`

**Status:** Locally complete on 2026-08-29. Integrated evidence:
`Docs/evidence/2026-08-29-ai-redesign-slice-5-verification.md`. Live provider,
physical-device, credential, deployment, and production policy gates remain
explicitly outside local completion.

## Outcome and proof

Slice 5 is complete only when two independent logical clients starting from one hosted head can upload distinct immutable candidates, exactly one candidate becomes the new canonical head, the other remains a downloadable stale branch, and no code path silently merges or discards either branch. An interrupted or corrupt upload must not change a local or hosted head; exact retries must be idempotent; a second device must recover the validated room package and its supported companions; and the default active-object inventory must contain no RGB, depth, confidence, diagnostics, capture-bundle, or world-map bytes.

## Global constraints

- Start from local `main` commit `ee102b2` and preserve its one-commit lead over `origin/main`; never reset, rebase, overwrite, commit, push, deploy, or provision.
- “A stale upload preserves both branches and requires explicit comparison, rebase, or duplicate; it never silently merges or drops a revision.”
- “There is no last-writer-wins or automatic-merge value.”
- “The policy is an outbound contract, not a setting that causes Slice 0 to enumerate or upload local capture sidecars.”
- Guest scan, save, view, edit, export, import, AI package, Concept Set, and Share Sheet flows remain offline, account-free, and unable to construct or call a hosted transport.
- Private CloudKit backup remains a separate explicit service; professional synchronization must not reuse its coordinator, transport, container, zone, records, journal, or feature controls.
- Local packages and immutable local revisions remain capture truth. Network failure, lease expiry, conflict, or rollback must never block a local save or delete a local package/draft.
- Caller-supplied workspace, project, revision, upload, or object identifiers are consistency/resource inputs only. Authentication, workspace membership, role, current resource ownership, flags, quota, and tenant scope are derived and rechecked server-side in the mutation transaction.
- All new tenant tables use forced RLS. Credential-backed API/worker runtime roles follow the established PostgreSQL/Data API wiring as `LOGIN NOINHERIT`, non-owner, non-superuser, without `BYPASSRLS` or role-membership edges; login is usable only through operator-managed Secrets Manager credentials, and workers receive only narrow server-selected function capabilities. `NOLOGIN` remains appropriate only for policy/ownership roles that are never used as Data API principals.
- Object keys, database UUIDs, S3 version IDs, presigned URLs, request bodies, filenames, room bytes, tokens, email addresses, GPS, and free-form project content are absent from ordinary logs and audit subjects.
- Upload capabilities expire after 300 seconds, use immutable server-selected quarantine keys and `If-None-Match: *`, and are never project authorization.
- The edit lease duration is exactly 900 seconds, uses server time, and is advisory. It coordinates editor entry but never bypasses authorization or the expected-head CAS, and queued offline drafts may still be submitted after reconnect.
- Production quota values, price copy, retention periods, lifecycle deletion, and provider limits remain explicit release gates. Only the existing `test-only` quota policy is used locally.
- No Slice 6 publication/portal route, published derivative, protected link, or web client is added. No Slice 7 resource/operations product work is added.

## Scope

- Versioned Core contracts for initial hosted head creation, immutable append, separate raw attachment, working-set envelope, archive descriptors, conflicts, leases, and recovery progress.
- A raw-redacted transport materialization that rewrites only an external copy of `manifest.json`, clears `assetPolicy.worldMap`, excludes that file, and leaves the authoritative package byte-for-byte untouched.
- A deterministic professional working-set archive containing the package backup plus canonical redesign/orientation, Concept Set manifests/attachments, and only the canonical AI-ready Room Package provenance manifests required for automatic Concept mappings, with exact closure, byte, digest, source-revision, and coordinate-epoch validation. It never carries AI artifact payloads or raw evidence in that provenance family; Complete package manifests are excluded because their raw ledger is itself outside the default working-set schema path.
- A separate deterministic raw archive built only after an accepted size/privacy review from the bound capture bundle and any supported raw-only project artifact.
- An additive PostgreSQL `0008` migration with immutable revisions/objects, durable upload state, CAS finalization, branch preservation, idempotency, quota reservation/finalization/release, bounded leases, forced RLS, reducers, audit, and one validation-worker role.
- A new sealed Slice 5 HTTP route-set version that contains the unchanged 19 Slice 4 routes plus 10 explicit project-sync routes.
- Quarantine allocation, completion-to-durable-pending, targetless worker wake/recovery, server archive validation, immutable active promotion, status, signed download, raw configuration/attachment, and leases.
- A professional-only app journal, migration preview/progress/retry, offline draft detection, conflict compare/rebase/duplicate state, staged recovery, and explicit raw review.
- Infrastructure wiring for one validation queue/DLQ, recovery schedule, worker Lambda/runtime role, least-privilege S3/SQS/KMS/Data API access, alarms, migration ledger, and outputs.
- Focused/red-green/mutation/full-matrix verification and Slice 5 contract, architecture, privacy, runbook, README, and evidence updates.

## Exclusions

- Real-time collaboration, multi-writer editing, CRDT/OT, automatic geometry merge, last-writer-wins, background upload on local save, launch-time sync, or automatic migration.
- Publication snapshots, portals, protected links, published/public buckets, portal analytics, SEO, or browser delivery.
- Cross-room alignment, property transforms, construction truth, code compliance, or survey claims.
- Production deployment, credentials, customer data, AWS account mutations, pricing/retention promises, physical-device background-transfer proof, and provider conformance claims.
- Changes to existing local package schema readability or private CloudKit backup semantics.

## Affected boundaries and compatibility strategy

| Boundary | Additive Slice 5 change | Compatibility rule |
|---|---|---|
| Core package | `RoomProfessionalSyncContracts.swift`, `RoomProfessionalWorkingSetArchive.swift`, raw-redacted materialization/recovery companion helpers | Keep `roomscan-working-project-sync-v1`, package v1/v2, `RoomProjectBackupArchive`, and existing validators readable and behaviorally unchanged. Add separate `initialProjectSync`, `professionalWorkingSet`, and `rawArchiveAttachment` v1 contracts rather than using a sentinel head. A hosted recovery response deliberately supplies only the outer digest/size and manifest digest; Core derives the complete local descriptor only by safely inspecting that digest-bound archive manifest before invoking the existing full extraction/recovery boundary. |
| Local stores | External raw-redacted package copy; snapshot/restore APIs for redesign and Concept Sets | Never rewrite the live package or rebind a companion implicitly. Explicit recover-as-copy can rebind source-bound local companions only through the actual promoted copy binding; exact AI-ready Room Package provenance is original-ID-only, while copied and Complete-only automatic Concept mappings downgrade to manual rather than fabricating a newly reviewed AI package or carrying a raw ledger into the default object. |
| App professional boundary | Lazy sync coordinator, non-authoritative journal, transport client, migration/conflict/recovery UI | Default-off guest composition constructs no network client. Signed URLs are transient and never persisted. CloudKit files/classes remain untouched except shared local-store façade calls. |
| HTTP contract | `roomscan-slice5-routes-v1`, 29 exact routes | Preserve `SLICE4_ROUTE_SET_VERSION == roomscan-slice4-routes-v3` and its exact 19-route manifest as a legacy export. No generic registration or Slice 6 route. |
| PostgreSQL | Forward-only `0008_professional_project_sync.up.sql` | Fresh install and staged `0001`–`0007` upgrade must converge. No destructive rewrite or down migration; disable flags/workers for rollback. |
| Object storage | Existing quarantine and private-active buckets, new sync prefixes | Default working and opt-in raw objects use distinct server-selected prefixes and ledger rows. Published/backup buckets are not used. Active objects are never overwritten or deleted by runtime roles. |
| Infrastructure | Validation queue/DLQ/schedule/worker/IAM/alarm and updated migration digest | Existing Slice 4 roots/routes/queues remain. Synthetic local configuration only; no deployment. |

**Recovered-copy and provenance clarification (evidence-driven):** A package recover-as-copy rewrites the project identifier in the copied semantic and revision documents. Their SHA-256 bindings therefore change legitimately. Local redesign and Concept source rebinding must use the actual `RoomRedesignSourceRevision` derived by `LocalRoomProjectStore` from that validated promoted copy, preserving the immutable revision ID, coordinate-space epoch, and package schema while accepting only those store-derived rewritten digests. A caller-provided project ID or digest is never sufficient authority to rebind a companion. Exact canonical `RoomAIRoomPackage` provenance remains valid only for same-ID recovery, and the default working-set path admits only `.aiReady` package manifests because a Complete manifest enumerates raw slots even when payload bytes are absent. Creating a copy-bound package would require fabricating or reusing a disclosure review for a different revision manifest. Recover-as-copy, and any automatic Concept whose only authority is an excluded Complete package, therefore preserves Concept bytes and origin claims but deterministically downgrades automatic camera mappings to manual (or unmatched only when the destination camera cannot be validated), and typed build/recovery results surface that adjustment.

**Recovery descriptor clarification (evidence-driven):** The service cannot safely reconstruct or expose the full Core working-set descriptor because its project and revision public IDs are hosted identifiers, while the complete inner package descriptor and local source IDs are intentionally contained only in the immutable archive manifest. A recovery client must therefore verify the downloaded outer digest and byte count, safely extract into a caller-owned empty scratch directory, require the canonical manifest digest to equal `workingSetManifestSHA256`, strict-decode and validate the manifest/outer closure, derive `RoomProfessionalWorkingSetDescriptor`, clean the scratch directory, and only then call `extractAndVerify` and the package recovery coordinator. No service response field is trusted as a local project/package descriptor and inspection never mutates live state.

## Frozen contracts and interfaces

The Core types introduced by Task 1 are the single vocabulary used by app fixtures, service golden fixtures, documentation, and the cross-runtime verifier:

```swift
public enum RoomProfessionalSyncOperation: String, Codable, Sendable {
    case createInitialHead
    case appendRevision
    case attachRawArchive
}

public struct RoomInitialProjectSyncV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-initial-project-sync-v1"
    public let sourceProjectID: String
    public let proposedRevisionID: String
    public let workingSetManifestSHA256: String
    public let archiveSHA256: String
    public let archiveByteCount: UInt64
}

public struct RoomRawArchiveAttachmentV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-raw-archive-attachment-v1"
    public let projectID: String
    public let revisionID: String
    public let review: RoomRawDisclosureReview
    public let manifestSHA256: String
    public let archiveSHA256: String
    public let archiveByteCount: UInt64
}

public struct RoomProfessionalWorkingSetDescriptor: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-professional-working-set-v1"
    public let snapshotID: String
    public let projectID: String
    public let headRevisionID: String
    public let packageDescriptor: RoomCloudBackupDescriptor
    public let archiveSHA256: String
    public let archiveByteCount: UInt64
}
```

The 10 new routes are exact and bring the Slice 5 manifest to 29 routes:

```text
POST /projects/migration/allocate       project.migration.allocate
POST /projects/revisions/allocate       project.revision.allocate
POST /projects/uploads/complete         project.upload.complete
POST /projects/uploads/status           project.upload.status
POST /projects/recovery/allocate        project.recovery.allocate
POST /projects/edit-lease/acquire       project.edit-lease.acquire
POST /projects/edit-lease/renew         project.edit-lease.renew
POST /projects/edit-lease/release       project.edit-lease.release
POST /projects/raw-archive/configure    project.raw-archive.configure
POST /projects/raw-archive/allocate     project.raw-archive.allocate
```

Allocation and completion return no internal UUID/key/version. Client-visible identifiers are server-minted opaque public IDs. A successful append status is `canonical`; a failed head CAS is `stale` with both `candidateRevisionID` and `currentHostedHeadRevisionID`; invalid bytes are `rejected`; incomplete states are `allocated`, `validationPending`, or `validating`.

The durable worker state transition is fixed:

```text
allocated -> validation_pending -> validating -> canonical | stale | rejected
    |             ^                    |
    |             +---- lease expiry --+
    +---- authoritative expiry reap -> rejected/tombstoned (reservation released)
```

The completion message contains only `roomscan-project-validation-wake-v1`; the worker first calls the worker-only, targetless `reap_expired_project_upload_v1(authoritative_time)` to release quota and tombstone expired `allocated` uploads, then claims the oldest eligible completed row server-side. `claim_next_project_validation_v1` never claims incomplete allocations. Exact retry before expiry remains unchanged and no public route exposes reaping. Crash recovery must be idempotent at allocation-before-presign, PUT-before-complete, complete-before-SQS, mid-validation, active-copy-before-CAS, and CAS-before-response.

## Ordered tasks

### Task 1: Core sync, working-set, raw, and companion contracts

**Files:**

- Create: `RoomScanCore/Sources/RoomScanCore/RoomProfessionalSyncContracts.swift`
- Create: `RoomScanCore/Sources/RoomScanCore/RoomProfessionalWorkingSetArchive.swift`
- Create: `RoomScanCore/Sources/RoomScanCore/RoomProfessionalRawArchive.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/LocalRoomProjectStore.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/LocalRoomRedesignStore.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/LocalRoomConceptStore.swift`
- Test: `RoomScanCore/Tests/RoomScanCoreTests/RoomProfessionalSyncContractTests.swift`
- Test: `RoomScanCore/Tests/RoomScanCoreTests/RoomProfessionalWorkingSetArchiveTests.swift`
- Test: `RoomScanCore/Tests/RoomScanCoreTests/RoomProfessionalRecoveryTests.swift`
- Fixture: `RoomScanCore/Tests/RoomScanCoreTests/Fixtures/ProfessionalSync/`

**Interfaces:**

- Consumes: existing immutable package/revision models, deterministic ZIP, backup archive, redesign canonical JSON, Concept Set validation/import, and working-sync v1 validator.
- Produces: the frozen types above; `LocalRoomProjectStore.materializeProfessionalWorkingCopy(projectID:expectedHeadRevisionID:into:)`; `RoomProfessionalWorkingSetArchive.build`, digest-bound `inspectDownloadedArchive`, and `extractAndVerify`; `RoomProfessionalRawArchive.build`, `extractAndVerify`; `LocalRoomConceptStore.snapshot` and idempotent `restoreSnapshot`; exact canonical AI-ready Room Package provenance snapshots for original-ID automatic Concept recovery; typed automatic-to-manual/unmatched transport/recovery adjustments for Complete-only or copied Concepts; and source companion rebind only for an explicit recovered-copy ID mapping plus the actual store-derived recovered-copy source revision.

- [x] Add tests that first fail to compile because the new contract/archive types do not exist. Cover strict unknown-key rejection, canonical JSON, null-head initial creation, non-null expected-head append, raw attachment not moving a head, exact asset-slot ledger, and the absence of merge/last-writer-wins enum cases.
- [x] Run `swift test --package-path . --filter RoomProfessionalSyncContractTests` and retain the compile/test failure as the Core red artifact.
- [x] Implement the three new versioned contract families without changing `RoomWorkingProjectSync` v1 decoding or validation.
- [x] Add a raw-redacted external materializer. It must copy from the validated live package, clear only `assetPolicy.worldMap` in the copied `manifest.json`, omit that referenced file, keep native USDZ/raw mesh and every immutable revision, validate the resulting copy, and leave the live package digest and contents unchanged.
- [x] Build the outer deterministic working-set archive with exact allowed entries: one package backup blob, optional canonical redesign companion, zero or more canonical Concept Set manifests/attachments, zero or more exact canonical `.aiReady` `RoomAIRoomPackage` provenance manifests required by included automatic Concept Sets, and `working-set-manifest.json`. The provenance family carries no AI artifact payload or raw evidence; reject Complete manifests because their raw ledger is outside the default working-set schema path. Bind every entry to project/head/source revision/coordinate epoch and require full entry closure, including missing/extra/duplicate/case-colliding provenance manifests.
- [x] Build the separately reviewed raw archive from explicit caller inputs classified as RGB, depth, confidence, diagnostics, or world map. Require accepted `RoomRawDisclosureReview`, exact byte/digest closure, safe ASCII paths, and no working-set entries.
- [x] Add snapshot/restore APIs that validate all companion bytes before promotion. Original-ID recovery preserves exact canonical AI-ready Room Package provenance and automatic Concept mappings. Complete-only package authority is never emitted on the default working-set path and deterministically downgrades automatic mappings in the transport snapshot. Explicit recover-as-copy uses the validated destination package's derived source revision (same revision/epoch/schema, actual rewritten semantic/revision digests) for local companion rebind, never fabricates or reuses a disclosure review for a copied AI package, and deterministically downgrades automatic Concept mappings to manual (or unmatched only when destination camera validation fails). Typed build/recovery adjustments surface each downgrade. It never rewrites the hosted stale branch.
- [x] Add positive detector controls by injecting each forbidden raw class into a default working archive and asserting a typed rejection, then prove an accepted raw archive accepts the same bound fixture separately.
- [x] Add a digest-bound download inspection test with a valid archive control. It must derive the complete local descriptor only from the strict manifest after verifying the hosted outer digest/size and `workingSetManifestSHA256`, leave caller scratch empty, and fail when the manifest-digest guard is neutralized.
- [x] Add interruption tests at package commit and companion promotion. Package/live companions remain unchanged before commit; a post-package crash records resumable companion promotion and an exact retry completes idempotently.
- [x] Run the three focused Core suites, then `swift test --package-path .`; expected count is greater than the 266-test baseline.

### Task 2: PostgreSQL 16 immutable lineage, upload state, CAS, raw attachment, and leases

**Files:**

- Create: `HostedService/db/migrations/0008_professional_project_sync.up.sql`
- Create: `HostedService/db/test/integration-0008-project-sync.mjs`
- Create: `HostedService/db/test/integration-0008-project-sync-security.mjs`
- Create: `HostedService/db/test/mutations-0008-project-sync.mjs`
- Modify: `HostedService/db/package.json`
- Modify: `HostedService/db/test/staged-upgrade.mjs`
- Modify: migration-ledger expectations under `HostedService/infra/`

**Interfaces:**

- Consumes: existing `projects`, access-digest workspace context, action/flag authorization, v2 quota reservations, audit sequence, forced-RLS patterns, and server-time conventions.
- Produces: API reducers for migration allocation, append allocation, completion, status, recovery lookup, raw configuration/allocation, and lease acquire/renew/release; worker-only targetless `reap_expired_project_upload_v1(authoritative_time)`, claim/release/finalize reducers; immutable revision/object rows; exact CAS result `canonical | stale`.

The additive schema is:

`proposed_revision_id` remains the client/source immutable revision identifier;
`candidate_revision_public_id` is the server-minted public identifier surfaced
as `candidateRevisionID`. `target_revision_id` remains the internal UUID.

```sql
roomscan.professional_projects(workspace_id, project_id, public_id, source_project_id,
  head_revision_id, raw_archive_enabled, raw_reviewed_at, version, created_at, updated_at)
roomscan.project_uploads(workspace_id, id, public_id, project_id,
  project_public_id, source_project_id, operation,
  idempotency_digest, proposed_revision_id, candidate_revision_public_id,
  target_revision_id, expected_head_revision_id, expected_head_source_revision_id,
  working_manifest_digest, working_digest, working_bytes,
  raw_manifest_digest, raw_digest, raw_bytes, raw_review_digest, state,
  quarantine_key, quarantine_version, active_object_key, active_object_version,
  lease_id, lease_expires_at, validation_attempts, rejection_code,
  allocation_expires_at, created_by_principal_id, created_at, updated_at)
roomscan.project_revisions(workspace_id, id, public_id, project_id, parent_revision_id,
  source_revision_id, branch_state, working_object_key, working_object_version,
  working_digest, working_bytes, working_manifest_digest, created_at)
roomscan.project_raw_archives(workspace_id, revision_id, object_key, object_version,
  manifest_digest, archive_digest, archive_bytes, review_digest, created_at)
roomscan.project_edit_leases(workspace_id, project_id, holder_principal_id,
  holder_device_digest, request_digest, token_digest, generation, expires_at, updated_at)
```

Internal UUIDs, client/source revision identifiers, and server-minted public identifiers are distinct columns: Core declarations use source identifiers, database relations use UUIDs, and HTTP exposes only public identifiers. Allocation mints public upload/candidate IDs and derives then persists fixed unique quarantine/active keys from those server-minted IDs; callers never supply keys. Server-selected active keys are persisted at allocation so promotion is retry-safe; raw manifest/review digests are persisted because the Core attachment contract validates them; lease request digests make a lost acquire response exactly retryable. These additions are required state, not new product behavior.

Initial migration allocation is pre-project staging: it mints and persists `project_public_id`, stores `source_project_id`, reserves `project_count` and working bytes without a project resource, and leaves nullable `project_id` unset. Only successful server validation creates the generic `roomscan.projects` row and `professional_projects` row, links `project_id`, finalizes both quotas, inserts the initial immutable revision, and performs the null-head CAS in the same transaction. A rejected/corrupt initial upload releases both reservations, retains only its rejected/idempotency tombstone, and creates no hosted project shell. This follows the approved validate-stage-promote rule and avoids counting or exposing an invalid migration. Appends/raw attachments always require an existing non-null `project_id`. A partial unique constraint permits only one nonterminal initial migration per workspace/source project; rejected attempts may be retried with a changed declaration/idempotency digest.

- [x] Write fresh-install and staged-upgrade tests that fail because `0008` and its reducers/role do not exist. Include two separately authenticated logical clients in one workspace and same-tenant positive controls for every cross-tenant denial.
- [x] Run the two `integration-0008` tests against disposable PostgreSQL 16 and retain the red output.
- [x] Add tables/checks/unique indexes/foreign keys/forced RLS/policies and the credential-backed `roomscan_project_sync_runtime` worker role as `LOGIN NOINHERIT`, matching the existing Data API bootstrap contract. It must remain non-owner/non-superuser, have no `BYPASSRLS` or role-membership edges, and receive only exact worker-function ACLs. Internal object keys/UUIDs must never be returned by API reducers.
- [x] Implement exact-retry allocation: the same principal/idempotency digest/declaration returns the original public allocation while its internally persisted derived keys remain unchanged; any changed declaration under the key fails closed. Initial allocation creates no generic/professional project row: it pre-mints the public project ID, stores the source project ID, reserves project-count/working quotas without a project resource, and permits only one nonterminal migration for that workspace/source. Append binds the current expected head without changing it during allocation.
- [x] Implement completion as a transaction from `allocated` to `validation_pending`. It cannot accept caller state, object keys, tenant IDs, validator results, or head values.
- [x] Implement worker-only targetless `reap_expired_project_upload_v1(authoritative_time)` before claim: it locks expired `allocated` uploads, releases their v2 quota reservations, and leaves rejected/tombstoned idempotency state without creating a public route. Exact allocation retry before expiry remains unchanged. Implement a targetless worker claim with `FOR UPDATE SKIP LOCKED`, a lease bounded to 900 seconds, expired-lease reclamation, exact lease release, server-selected tenant/project/object data, and an eligibility predicate that excludes incomplete `allocated` uploads.
- [x] Implement finalization in one transaction. For a validated initial migration, create the server-derived generic project row and professional row, link the upload, insert the immutable revision, perform the null-head CAS, and finalize project-count plus working quota. For append, insert the revision and perform `UPDATE professional_projects SET head_revision_id = candidate WHERE head_revision_id IS NOT DISTINCT FROM expected`, setting `canonical` on one row or `stale` on the other while preserving both rows/objects. Invalid initial candidates release both reservations and create no hosted project shell/revision; invalid append/raw candidates release their reservations. Append audit in all terminal transitions.
- [x] Implement raw attachment as a separate reducer bound to an existing validated revision and accepted owner review; it finalizes `raw_bytes` but never changes `head_revision_id`. Raw validation failure never blocks a previously canonical working revision.
- [x] Implement server-time 900-second lease acquire/renew/release with unguessable token digest, one live holder, expired takeover, exact idempotent retry, and no effect on CAS semantics.
- [x] Run two-client, interrupted-state, exact-retry, allocated-expiry quota-reap, raw, lease, RLS, role, null, and staged-upgrade integration tests.
- [x] Neutralize the live expected-head predicate in a temporary migration copy and run `mutations-0008-project-sync.mjs`; the two-client oracle must fail because both candidates become canonical. Restore the predicate and rerun green. Also mutate targetless claim and forced-RLS clauses and require their focused controls to fail.
- [x] Run `npm --prefix HostedService/db test`; all Slice 4 tests plus new `0008` tests must pass on PostgreSQL 16.

### Task 3: Versioned HTTP contract, application ports, validators, and worker

**Files:**

- Create: `HostedService/service/src/contracts/project-sync.ts`
- Create: `HostedService/service/src/sync/archive-validator.ts`
- Create: `HostedService/service/src/sync/project-sync-worker.ts`
- Create: `HostedService/service/src/adapters/s3-project-sync.ts`
- Create: `HostedService/service/src/persistence/project-sync-capabilities.ts`
- Create: `HostedService/service/src/composition/project-sync-application.ts`
- Create: `HostedService/service/test/project-sync-routes.test.ts`
- Create: `HostedService/service/test/project-sync-worker.test.ts`
- Create: `HostedService/service/test/project-sync-archive-validator.test.ts`
- Modify: `HostedService/service/src/contracts/route-manifest.ts`
- Modify: `HostedService/service/src/contracts/openapi.ts`
- Modify: `HostedService/service/src/contracts/transaction-bound-repositories.ts`
- Modify: `HostedService/service/src/handlers/factory.ts`
- Modify: `HostedService/service/src/persistence/capabilities.ts`
- Modify: `HostedService/service/src/persistence/operation-port.ts`
- Modify: `HostedService/service/src/composition/production.ts`
- Modify: `HostedService/service/src/contracts/index.ts`
- Modify: `HostedService/service/src/handlers/index.ts`
- Modify: `HostedService/service/src/persistence/index.ts`

**Interfaces:**

- Consumes: Task 1 golden archives/contracts and Task 2 reducer signatures; existing route schema/parser, authorization matrix, Data API transaction executor, quarantine allocator, privacy logger, and S3 boundary.
- Produces: `SLICE5_ROUTE_SET_VERSION == "roomscan-slice5-routes-v1"`, exact 29-route `SLICE5_ROUTE_MANIFEST`, typed project-sync ports, post-commit capability execution, archive validator, worker, signed upload/download results, and typed status/conflict responses.

- [x] Add route/OpenAPI/schema/authorization tests that fail because the 10 routes and Slice 5 manifest do not exist. Assert Slice 4 remains exactly 19 routes/v3 and Slice 5 is exactly 29 routes/v1.
- [x] Add validator/worker tests using golden archives generated by Task 1 and malicious variants for duplicate decoded keys, traversal, case collisions, symlinks/non-STORE ZIP, CRC/digest/size/closure mismatch, wrong project/head/epoch, raw content in default working set, and invalid review.
- [x] Run focused service tests and retain the red output.
- [x] Generalize the sealed handler internally while preserving `createSlice4HandlerEntrypoint`. Add `createSlice5HandlerEntrypoint` and a branded post-commit result whose provider closure executes only after the protected mutation transaction commits. A public route cannot emit this result.
- [x] Add the 10 exact routes with bounded JSON schemas. Extend resource resolution for `project`, `revision`, and `upload` through transaction-bound capabilities; no handler receives raw SQL, internal UUID, tenant ID, provider client, or object key.
- [x] Implement migration/append/raw allocation by transactionally obtaining an opaque allocation record and quota reservation, then having the trusted service object adapter derive the same persisted server-selected quarantine key only after commit for presigning. Exact retry returns the same allocation/IDs/keys but mints a fresh short-lived URL; HTTP/status never returns keys or versions, the URL is never stored in PostgreSQL, and worker claim alone receives stored internal keys/versions.
- [x] Implement completion as durable pending followed by a generic queue wake after commit. Every worker wake/recovery tick first runs the worker-only targetless allocated-expiry reap, then claims completed validation work. If SQS fails, return retryable status while leaving pending work recoverable by schedule; incomplete allocations are never validated.
- [x] Implement server validation of the exact S3 object version, length/checksum/content type, outer and nested ZIP32 STORE structure, canonical manifests, entry closure/digests, source bindings, and default raw exclusions. Do not trust client digests without hashing bytes.
- [x] Promote to a unique active key/version, verify the promoted object, then call Task 2 finalization. Every worker step is retry-safe; no worker API accepts a client-selected target.
- [x] Implement status/recovery results with public IDs only. Recovery is a read/export operation: it signs the selected canonical or stale active object after the authorized transaction, remains available when hosted writes are disabled, and repeated calls return the same public target/digest/size with a fresh transient URL and no durable recovery row. Stale branches remain downloadable for compare/duplicate.
- [x] Implement raw configuration with owner/recent-auth and raw allocation with the existing action matrix. Keep working and raw object adapters/keys/quotas separate.
- [x] Add explicit privacy-log tests ensuring request bodies, filenames, object keys/versions, URLs, room bytes, tokens, and free-form text are never logged.
- [x] Neutralize the raw-path detector in a temporary compiled source copy; the intentionally injected forbidden artifact must make the focused negative test fail. Restore and rerun with both the default clean control and accepted separate raw positive control green.
- [x] Run `npm --prefix HostedService run typecheck`, `npm --prefix HostedService run build`, and `npm --prefix HostedService test`.

### Task 4: Infrastructure wiring and migration compatibility

**Files:**

- Create: `HostedService/infra/src/functions/project-sync-validation.ts`
- Create: `HostedService/infra/test/slice5-project-sync.test.ts`
- Create: `HostedService/infra/test/slice5-project-sync-mutations.ts`
- Modify: `HostedService/infra/src/functions/slice4-runtime-roots.ts` (rename only if exports remain backward-compatible; otherwise add a Slice 5 root beside it)
- Modify: `HostedService/infra/src/aws/runtime-clients.ts`
- Modify: `HostedService/infra/src/aws/runtime-credential-bootstrap.ts`
- Modify: `HostedService/infra/src/stacks/platform-stack.ts`
- Modify: `HostedService/infra/src/functions/migration-operator.ts`
- Modify: `HostedService/infra/src/migration-operator/direct-postgres.ts`
- Modify: `HostedService/infra/scripts/generate-migration-manifest.mjs`
- Modify: `HostedService/infra/assets/migration-manifest.json`

**Interfaces:**

- Consumes: Task 2 migration/role and Task 3 API/worker composition.
- Produces: validation queue/DLQ/recovery schedule, Lambda entrypoint, least-privilege IAM, S3 active read/copy/version verification, Data API worker secret, alarms/outputs, and a digest-pinned eight-migration ledger.

- [x] Add CDK/template/runtime-root tests that fail because the worker, queue, IAM, alarm, output, and `0008` digest are absent.
- [x] Run `npm --prefix HostedService/infra run test:local` and retain the focused red failures.
- [x] Add an encrypted validation queue and DLQ, 5 receive attempts, bounded visibility timeout, targetless recovery schedule, one worker Lambda, DLQ alarm, and non-sensitive outputs.
- [x] Grant API only quarantine `PutObject`/presign and generic SQS wake; grant the worker only quarantine read/version metadata, unique private-active copy/write/read verification, queue consume, KMS use, its Data API secret, and worker reducers. Grant download signing read-only private-active access through its narrow adapter. No runtime delete or published/backup access.
- [x] Wire `roomscan_project_sync_runtime` through bootstrap without caller-selectable role names. Update every exact migration ledger/digest seam and prove staged `0001`–`0007` upgrade applies only `0008`.
- [x] Add template mutation controls for missing forced encryption, public access block, versioning, DLQ, schedule, least-privilege prefix, CloudTrail active/quarantine data events, and migration digest.
- [x] Run infra typecheck, local tests, mutation tests, CDK synth/inspection, and offline verify. Keep provider assertions labeled synthetic.

### Task 5: App migration, journal, transport, offline drafts, conflict actions, and recovery

**Files:**

- Create: `RoomScanStudio/Infrastructure/ProfessionalSync/ProfessionalProjectSyncModels.swift`
- Create: `RoomScanStudio/Infrastructure/ProfessionalSync/ProfessionalProjectSyncJournal.swift`
- Create: `RoomScanStudio/Infrastructure/ProfessionalSync/ProfessionalProjectSyncTransport.swift`
- Create: `RoomScanStudio/Infrastructure/ProfessionalSync/ProfessionalProjectSyncService.swift`
- Create: `RoomScanStudio/Infrastructure/ProfessionalSync/ProfessionalProjectRecoveryCoordinator.swift`
- Create: `RoomScanStudio/Infrastructure/ProfessionalSync/ProfessionalRawArchiveMaterializer.swift`
- Create: `RoomScanStudio/RoomScanStudioTests/ProfessionalProjectSyncTests.swift`
- Create: `RoomScanStudio/RoomScanStudioTests/ProfessionalProjectRecoveryTests.swift`
- Modify: `RoomScanStudio/Infrastructure/Persistence/RoomLibraryController.swift`
- Modify: `RoomScanStudio/Professional/ProfessionalEnvironment.swift`
- Modify: `RoomScanStudio/Professional/ProfessionalTransportBoundary.swift`
- Modify: `RoomScanStudio/App/AppEnvironment.swift`
- Modify: `RoomScanStudio/Infrastructure/AIRedesign/RoomAIRedesignModelFactory.swift`
- Modify: `RoomScanStudio.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: Task 1 Core archive/recovery APIs and Task 3 public HTTP contract.
- Produces: a professional-only transport protocol/client; atomic non-authoritative journal; explicit preview/approve/retry; local-draft detection; lease calls; status/conflict model; compare/rebase-copy/duplicate-copy; staged second-device recovery that persists exact original-ID AI-ready-package provenance and visibly reports Complete-only/copied automatic-to-manual Concept mapping adjustments; separate raw review/materialization.

- [x] Add app tests that fail because the coordinator/journal/transport do not exist. Use two independent fake logical clients sharing one hosted fake, real local stores, and real Task 1 archives—not test-only reimplementations.
- [x] Run focused app unit tests and retain the red result.
- [x] Implement a marker-owned professional scratch root and atomic journal containing only public hosted mapping, acknowledged head, local draft head, stable idempotency digest, public allocation/status, conflict IDs, and resumable recovery phase. Never persist access/refresh tokens, lease plaintext after release, presigned URLs, object keys, DB IDs, or room bytes.
- [x] Implement migration preview by loading/validating the current local head, building and revalidating a working archive, showing exact working/raw-excluded categories and bytes/quota, and returning an immutable approval token bound to project/head/archive digest. Approval uploads only after explicit professional entry/unlock/session; retry reuses the idempotency key; no path calls `delete`, `archive`, or edits the source package.
- [x] Keep local save unchanged. On professional refresh/sync, compare local immutable head with the journal’s acknowledged hosted head and mark a different local head as `localDraft`; do not upload on launch, save, foreground, or offline transition.
- [x] Implement upload as allocate -> signed PUT -> complete -> poll status. Interruption retains local archive/journal state for exact retry. A stale status stores both public revision IDs and exposes only `compare`, `startRebaseFromHostedHead`, and `recoverBranchAsDuplicate`.
- [x] Implement compare by downloading/staging/validating canonical and stale envelopes and returning read-only semantic/manifest/companion digest differences. It never promotes or creates geometry.
- [x] Implement rebase as an explicit recovery of the current hosted head as a local copy, companion source rebind, deterministic automatic-to-manual Concept mapping downgrade, and `awaitingUserEdit` state. Never synthesize a copy-bound AI Package disclosure review; only original-ID recovery persists exact canonical AI-ready package provenance, while Complete-only provenance is never uploaded in the default path. Only a later user-saved immutable child may append with the then-current hosted head; never rewrite the stale candidate’s parent.
- [x] Implement duplicate as explicit stale-branch recovery-as-copy followed by a separate migration preview. Do not silently create a hosted project.
- [x] Implement second-device recovery by staging/validating the outer envelope and all companions, calling existing `prepareBackupRecovery`, committing the package, then idempotently promoting companions. Original-ID recovery persists exact canonical AI-ready-package provenance required for automatic mappings; Complete-only and recover-as-copy transport snapshots report deterministic automatic-to-manual mapping adjustments and persist no raw-ledger or fabricated copy provenance. Corrupt/interrupted input never mutates live state; post-package interruption resumes companions.
- [x] Implement raw review showing exact byte count and categories. Only an accepted revision/plan/selection-bound review can build/upload a separate raw archive from the bound capture bundle. Default preview never enumerates capture-bundle files; the explicit raw materializer is the sole enumeration path.
- [x] Keep `ProfessionalEnvironmentFactory.defaultOff()` inert. Attach local project access after `RoomLibraryController` construction without constructing the configured hosted client; the hosted sync service remains lazy until explicit professional entry. Keep CloudKit types and transport untouched.
- [x] Add tests for no local deletion, exact retry, journal crash recovery, lost journal server reconciliation, offline draft preservation, zero guest requests, lease expiry/forgery, stale branch actions, raw default/opt-in, corrupt recovery, and companion resume.
- [x] Neutralize the staged-recovery promotion check in a temporary source copy; the corrupt-archive test must fail by observing a changed live package. Restore the guard and rerun green, including a valid recovery positive control.

### Task 6: Conflict and migration UX, responsive evidence, and guest regression

**Required skill before edits:** `frontend-design` as the design director; finish with `audit`, `polish`, and desktop-width/iPhone/iPad screenshot critique.

**Files:**

- Create: `RoomScanStudio/Features/Professional/ProfessionalProjectSyncView.swift`
- Create: `RoomScanStudio/Features/Professional/ProfessionalProjectConflictView.swift`
- Create: `RoomScanStudio/RoomScanStudioUITests/ProfessionalProjectSyncUITests.swift`
- Modify: `RoomScanStudio/Features/Professional/ProfessionalAccessView.swift`
- Modify: `RoomScanStudio/Professional/PhysicalProfessionalEvidenceHarness.swift`
- Modify: `RoomScanStudio.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: Task 5 coordinator states/actions.
- Produces: accessible explicit migration review/progress/retry; raw size/privacy confirmation; lease state; local-draft status; stale conflict comparison and deliberate rebase/duplicate entry points; deterministic zero-network UI fixture.

- [x] Add UI tests that fail because migration preview, progress/retry, raw review, and conflict actions are absent. Accessibility IDs are `professional.sync.preview`, `.approve`, `.progress`, `.retry`, `.rawReview`, `.conflict.compare`, `.conflict.rebase`, and `.conflict.duplicate`.
- [x] Present migration as a deliberate review: local room name/head, recoverable working categories, excluded raw categories, exact bytes, quota classification, “local room will remain on this device,” and one approval button.
- [x] Present progress by named phases (validate, allocate, upload, hosted validation, complete), retain retry after interruption, and never claim completion before hosted status is canonical or stale.
- [x] Present stale conflict with both revision IDs and explicit explanatory copy that geometry is not merged. Compare is read-only; Rebase explains that it starts from the hosted head and requires a new user edit; Duplicate explains it recovers the branch locally before a separate migration.
- [x] Present raw opt-in behind exact size/category/privacy review and owner/recent-auth availability. Do not show price or retention promises.
- [x] Keep protected UI obscured until local unlock and keep every guest view/action usable while professional state is unavailable, offline, or rolled back.
- [x] Capture and retain screenshots from the deterministic fixture at iPhone portrait, iPad portrait, and iPad landscape desktop-width. Critique hierarchy, Dynamic Type, contrast, VoiceOver labels/order, touch targets, overflow, and safe areas; fix findings before the full matrix.
- [x] Run the full UI schemes and ensure test counts exceed the prior 259-per-destination baseline.

### Task 7: End-to-end oracle, mutation controls, artifact inspection, and documentation

**Files:**

- Create: `Scripts/verify_slice5_sync.py`
- Create: `Scripts/verify_slice5_mutation_controls.py`
- Create: `Scripts/inspect_slice5_ios_artifact.py`
- Create: `Scripts/test_verify_slice5_sync.py`
- Create: `Scripts/test_verify_slice5_mutation_controls.py`
- Create: `Scripts/test_inspect_slice5_ios_artifact.py`
- Create: `Docs/contracts/ai-redesign-service-contracts-v2.md`
- Create: `Docs/evidence/2026-08-28-ai-redesign-slice-5-verification.md`
- Modify: `Docs/architecture.md`
- Modify: `Docs/privacy.md`
- Modify: `Docs/security/ai-redesign-threat-model.md`
- Modify: `Docs/operations/professional-service-runbook.md`
- Modify: `README.md`
- Modify: `Docs/verification-log.md`
- Modify: `ROOMSCANSTUDIO_MASTER_BUILD_PLAN.md`

**Interfaces:**

- Consumes: all prior task tests, fixtures, binaries, app schemes, PostgreSQL 16 harness, and CDK synthesizer.
- Produces: one hermetic Slice 5 verifier/artifact directory, mutation-control record, exact command/result ledger, compatibility/security/rollback documentation, and explicit external gates.

- [x] Add verifier self-tests that fail before the new script exists and prove the script rejects missing clauses, skipped controls, stale fixture digests, wrong Postgres version, count regressions, and forbidden raw inventory.
- [x] Implement the verifier so it uses two named logical clients, real Core-created archives, service validator/worker sources, PostgreSQL reducers, and a fake object provider with immutable version semantics. It must exercise all six crash cut points and recover pending work through a targetless tick.
- [x] Make the raw negative assertion include a positive detector control: inject one forbidden raw artifact, prove inspection finds it, then inspect the default uploaded active object and prove none exist. Also prove explicit reviewed raw attachment succeeds in its separate tier without moving the head.
- [x] Make recovery download the winning archive into a distinct second-device root, validate/promote through the existing package boundary, resume companions if interrupted, and compare project/head/semantic/redesign/orientation/Concept Set digests.
- [x] Inspect the generic unsigned built app for Slice 5 contract/version/conflict/raw-exclusion symbols and the absence of merge/last-writer-wins/publication route symbols.
- [x] Document the new v2 hosted contract, 29-route manifest, transactions, object tiers, privacy categories, runbook disable/recovery steps, forward-only migration, metrics/alarms, and rollback. Retain v1/Slice 4 contract history rather than rewriting it.
- [x] Record exact red/green and guard-neutralization outputs, test/build counts, screenshot artifacts, and the fact that local synthetic evidence is not provider/deployment/device evidence.

## Exact completion oracle

Run from repository root with no real credentials and no external account changes:

```sh
git status --short --branch
git rev-parse HEAD

swift test --package-path . \
  --scratch-path /private/tmp/roomscan-slice5-core \
  --disable-sandbox --no-parallel

npm --prefix HostedService run typecheck
npm --prefix HostedService run build
npm --prefix HostedService test

npm --prefix HostedService/db test

npm --prefix HostedService/infra run typecheck
npm --prefix HostedService/infra run test:local
npm --prefix HostedService/infra run test:mutations
npm --prefix HostedService/infra run verify

python3 -B Scripts/verify_slice4_hosted.py \
  --artifacts-dir .artifacts/slice4-hosted-slice5-regression
python3 -B Scripts/verify_slice5_mutation_controls.py \
  --artifacts-dir .artifacts/slice5-mutations
python3 -B Scripts/verify_slice5_sync.py \
  --artifacts-dir .artifacts/slice5-sync

xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/roomscan-slice5-iphone-derived \
  -resultBundlePath /private/tmp/roomscan-slice5-iphone.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test

xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /private/tmp/roomscan-slice5-ipad-derived \
  -resultBundlePath /private/tmp/roomscan-slice5-ipad.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test

xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/roomscan-slice5-generic-derived \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build

python3 -B Scripts/inspect_slice5_ios_artifact.py \
  --app /private/tmp/roomscan-slice5-generic-derived/Build/Products/Debug-iphoneos/RoomScanStudio.app \
  --output .artifacts/slice5-sync/ios-artifact-inspection.json \
  --require-marker roomscan-professional-working-set-v1 \
  --require-marker preserveBranchesRequireUserResolution \
  --forbid-marker lastWriterWins \
  --forbid-marker roomscan-slice6
```

The Slice 5 verifier passes only if its machine-readable report states all of the following:

1. Two independent clients allocate from the same hosted head; both immutable archives validate and promote; one and only one CAS is `canonical`; the other is `stale`; both active versions remain byte-identical and downloadable.
2. Allocation-before-presign, PUT-before-complete, complete-before-SQS, mid-validation, active-copy-before-CAS, and CAS-before-response recover idempotently; a worker-only targetless reap releases quota and tombstones expired incomplete allocations before claim while exact retry before expiry remains unchanged; interrupted/corrupt uploads leave both local and hosted heads unchanged until a valid finalization.
3. Initial migration performs exactly one CAS from no head, exact retry returns the same project/allocation/outcome, changed retry input is rejected, and the source local project remains loadable and unchanged.
4. Airplane-mode guest scan/save/view/edit/export/import tests pass with zero professional/auth/hosted requests; a local edit becomes an immutable draft and remains pending until explicit sync.
5. The default active working object contains no RGB, depth, confidence, diagnostics, capture-bundle, or world-map artifact. The detector first finds an intentionally injected forbidden artifact. Reviewed raw attachment succeeds only in the separate raw tier and never changes the head.
6. A second independent device root downloads the canonical object, stages and validates the envelope/package/companions, promotes through `prepareBackupRecovery`/`commitPreparedBackupRecovery`, and reproduces project ID, head revision, semantic digest, redesign/orientation digest, Concept Set/attachment digests, and exact canonical AI-ready-package provenance for original-ID automatic mappings. Complete package manifests are rejected from the default working path. Recover-as-copy uses only the store-derived destination binding, creates no copy-bound disclosure review/provenance, and visibly downgrades automatic mappings to manual (or unmatched only when the destination camera is invalid).
7. Every new cross-tenant denial has a same-tenant positive control; forced RLS, role capabilities, targetless worker claim, lease bounds, quota, logging redaction, route/OpenAPI parity, fresh install, and staged upgrade pass.
8. Swift package tests exceed 266; both complete iPhone and iPad schemes exceed 259; unsigned generic build and artifact inspection pass; prior Slice 4 hosted verifier remains green; required UI screenshots are attached and reviewed.

## Rollback point

Before enabling any Slice 5 write route, `hosted_operations_enabled` remains false globally and per workspace. Rollback sets it false, stops the project-validation event source/recovery schedule, denies new allocations/completions/raw attachments/leases, and leaves authenticated recovery downloads/export available under read authorization. Migration `0008` and all immutable quarantine/active objects remain in place; no destructive down migration or object deletion is performed. Every local package, draft, companion, export, private CloudKit backup, and guest workflow remains usable. The app’s professional transport can be replaced behind its protocol or left unavailable without changing local truth.

## External gates not claimed by local completion

- Physical-device Face ID/passcode and background-transfer behavior.
- Live AWS S3 conditional upload, checksum, KMS, versioning, copy, active-read, CloudTrail, lifecycle, and presigned URL behavior.
- Live SQS redrive/recovery, Lambda duration/memory/ephemeral-storage limits, Data API contention, Aurora PostgreSQL behavior, alarms, dashboards, and IAM propagation.
- Provider credentials, DNS/email/Apple/Stripe integration, production quotas/pricing/retention approval, deployment, release approval, and customer-data validation.

## Plan self-review

- Spec coverage: every Slice 5 roadmap bullet maps to Tasks 1–6 and every oracle clause maps to Task 7.
- Compatibility: initial migration and raw attachment have distinct contracts; Slice 4 v3 and working-sync v1 remain frozen; package v1/v2 and CloudKit remain readable/independent.
- Data-loss controls: allocation never moves a head; validation/promotion precedes one CAS; stale and raw records are immutable; recovery stages before promotion; leases are advisory.
- Storage controls: working package copy is raw-redacted, companions close the recoverable-set gap, raw is separately reviewed/stored, and detector controls exercise actual archives.
- Placeholder scan: no deferred implementation requirement or unspecified numeric default remains. Production-only policy numbers are explicitly gated, not invented.
- Type/route consistency: operation names, schema versions, status names, lease duration, route IDs/paths, manifest count, and rollback flags are consistent across tasks.
