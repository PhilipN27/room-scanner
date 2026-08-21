# AI redesign contracts v1

- Status: Slice 0–3 local package/resource contracts remain authoritative;
  Slice 4 professional-service contracts are documented separately
- Date: 2026-08-19
- Executable definitions:
  `RoomScanCore/Sources/RoomScanCore/RoomRedesignContracts.swift`,
  `RoomAIArtifactSelection.swift`, `RoomAIRoomPackageBuilder.swift`,
  `RoomAIRoomPackageArchive.swift`, `RoomConceptSet.swift`,
  `RoomConceptSetArchive.swift`, `LocalRoomConceptStore.swift`, and
  `RoomQuality.swift`
- Canonical fixtures:
  `RoomScanCore/Tests/RoomScanCoreTests/Fixtures/RedesignContracts`

These contracts originally described the implemented local Slice 3 boundary
and provider-neutral shapes before the optional professional service existed.
Slice 4 does not revise their bytes or compatibility rules; its app-owned API,
identity, authorization, quota, and provider-adapter contract is
[`ai-redesign-service-contracts-v1.md`](ai-redesign-service-contracts-v1.md).
The redesign interchange
documents are vendor-neutral public `Encodable` models with one fail-closed data
validator; their top-level models deliberately do not expose `Decodable`. The
revision-embedded quality report is `Codable` for legacy package compatibility,
but standalone untrusted bytes must cross
`RoomQualityReportDecoder.decodeCanonical`. The local package remains capture
truth; these documents bind to a validated immutable revision and never rewrite
it.

## Compatibility policy

Every redesign interchange document carries both `schemaVersion` and
`contractKind`; version and kind are one exact pair. The local-only property
container and the revision-bound quality report/carrier are separate canonical
models identified by `schemaVersion` and have no interchange `contractKind`:

| Contract | `contractKind` | `schemaVersion` |
| --- | --- | --- |
| Local redesign extension | `localRedesignExtension` | `roomscan-local-redesign-extension-v1` |
| Local spatial/redesign extension | `localRedesignExtension` | `roomscan-local-redesign-extension-v2` |
| Local property container | standalone local model (no `contractKind`) | `roomscan-property-container-v1` |
| Capture quality report | immutable revision member and standalone canonical model | `roomscan-quality-report-v1` |
| Future quality carrier | standalone provider-neutral model | `roomscan-quality-report-carrier-v1` |
| Hosted API resource | `hostedAPIResource` | `roomscan-hosted-api-resource-v1` |
| AI Room Package | `aiRoomPackage` | `roomscan-ai-room-package-v1` |
| Concept Set | standalone local/import model (no `contractKind`) | `roomscan-concept-set-v1` |
| Working-project sync | `workingProjectSync` | `roomscan-working-project-sync-v1` |
| Portal snapshot | `portalSnapshot` | `roomscan-portal-snapshot-v1` |

An unknown version, unknown kind, mismatched pair, duplicate JSON member
(including an escaped spelling of the same decoded key), unknown key at any
nesting level, malformed enum, or invalid cross-field combination is rejected.
Duplicate detection happens before object materialization, and typed decoding
uses that validated object tree rather than independently reparsing the
original bytes. Future versions must receive new fixtures and explicit
decoder/validator support; they are not decoded as v1 on a best-effort basis.

Schema evolution is additive and versioned at a deliberate boundary. A new
optional field may be introduced only when older readers can safely reject or
ignore the *new version as specified by that version's compatibility policy*.
V1 itself is strict: producers cannot add undeclared keys while retaining a v1
identifier.

## Shared scalar rules

- Stable IDs are 1--128 ASCII letters, digits, hyphens, or underscores.
- A v1 package-relative path is nonempty portable ASCII, is never absolute,
  uses `/`, contains no empty, `.` or `..` component, contains no colon,
  backslash, or control character, and remains within the package namespace.
  Path identity is ASCII-case-folded for collision detection, so case aliases
  fail before a case-insensitive target can materialize them. Restricting v1 to
  ASCII also removes NFC/NFD filename ambiguity; display names remain Unicode.
- A SHA-256 value is exactly 64 lowercase hexadecimal characters.
- Byte counts and resource versions are positive and bounded by their model.
- Every floating-point value is finite. Confidence is in the closed interval
  0...1; camera field of view is within the contract's physical bounds.
- IDs that identify entries in one array are unique.
- Timestamps are UTC ISO-8601 strings accepted by the contract validator.

`sourceRevision` is the shared truth binding:

```json
{
  "projectID": "project-001",
  "revisionID": "revision-001",
  "coordinateSpaceEpochID": "epoch-001",
  "packageSchemaVersion": "room-scan-project-v2",
  "revisionManifestSHA256": "<64 lowercase hexadecimal characters>",
  "semanticSHA256": "<64 lowercase hexadecimal characters>"
}
```

Nested orientation, concept, hosted, sync, and snapshot references must agree
with the enclosing source project, revision, coordinate-space epoch, manifest
digest, and semantic digest where those values are repeated. The manifest
digest binds lineage/metadata and the attachment inventory; every referenced
attachment also carries its own digest. A mismatch is invalid; the validator
never silently rebinds derived content.

## Local redesign extension

The local extension is additive state attached to one source revision. It may
contain:

- an orientation record with source (`suggested`, `confirmed`, or `manual`),
  confidence, entry position, nonzero inward direction, canonical right/up/
  forward axes, and uniquely identified canonical cameras;
- the verbatim nonempty redesign request, Stage/Renovate/Reimagine scope, and
  unique per-feature `preserve`, `mayChange`, or `requestedChange` permission;
- property membership expressed only as a property ID and independent room
  project IDs; and
- Concept Set metadata bound to the same immutable revision/digest, including
  scope, mapping status, and attachment records with path, SHA-256, byte count,
  and media type.

The v1 property structure deliberately has no room transform, alignment,
doorway connection, or inferred topology field. Concept metadata deliberately
has no captured geometry or measurement field. Unknown-key rejection therefore
turns attempted expansion under the v1 identifier into an error.

An orientation may exist locally while suggested, but later AI export and
publication readiness require the confirmed/manual product gate owned by the
later slice.

## Slice 1 local spatial extension

Slice 1 adds a new local-only extension version instead of altering v1 or any
immutable room-project revision. `roomscan-local-redesign-extension-v2` binds
to the exact source revision and coordinate-space epoch and contains:

- confirmed/manual entry position and inward direction, orientation source and
  confidence, right-handed canonical axes, and an explicit top-down
  orientation;
- deterministic entry, wall, corner, orbit, perspective, and top-down cameras
  derived from validated normalized room bounds;
- a required free-form redesign request, optional structured constraints,
  Stage/Renovate/Reimagine scope, and per-feature preserve/mayChange/
  requestedChange permissions stored separately from captured geometry;
- Concept Set provenance that is revision/epoch/digest bound and cannot carry
  or replace captured geometry, measurements, evidence, or lineage; and
- local orientation-readiness state. Suggested orientation can be retained for
  review, but only confirmed/manual orientation is eligible for later export or
  publication.

All vectors and cameras must be finite and non-degenerate. Axes must be
orthonormal and right-handed, cameras must have valid projection parameters,
and every repeated revision/epoch binding must match exactly. Invalid,
singular, inconsistent, or rebound input fails closed.

`roomscan-property-container-v1` groups independent local project IDs under a
display name. Its schema has no transforms, alignment, doorway connectivity,
shared coordinate system, or whole-property topology. Property membership is
stored beside—not inside—the immutable room packages.

Both documents use canonical JSON with sorted keys and stable SHA-256 digests.
Existing v1 documents, packages, and fixtures keep their original strict
decoders and bytes.

## Hosted API resource

The hosted resource contract is an app-owned envelope for a versioned resource
within one workspace. It declares resource type, stable IDs and scope,
monotonic version, lifecycle state, immutable source binding when applicable,
expected project head where applicable, and created/updated timestamps.

It is not a database row dump and contains no vendor SDK identifier, database
credential, object-store credential, bearer link secret, or authorization
decision. The hosted API derives authorization from the authenticated
canonical principal and server-owned membership, not from this document's
workspace ID alone.

Slice 4 implements only the professional identity/session/workspace/
membership/subscription/quota foundation described in the separate service
contract. It does not implement this document's working-project sync or portal
snapshot product behavior. Vendor types, internal database UUIDs, provider
tokens, ARNs, presigned URLs, and database rows remain outside both public
contract families.

## Artifact disposition

Plan and selection digests use one portable canonical projection: UTF-8 JSON,
the contract's ASCII object keys sorted lexicographically, arrays in their
explicitly documented sorted order, no insignificant whitespace, literal `/`
characters instead of `\/`, JSON strings for enum/scalar text, booleans for
flags, and base-10 unsigned integers for byte counts. Optional keys are omitted
rather than encoded as `null`; Unicode string values are emitted directly as
UTF-8 except for JSON's required quote, backslash, and control escapes. The
fixture suite pins cross-language golden SHA-256 vectors, including Unicode and
slash-bearing values, so a server implementation cannot substitute a vendor
JSON encoder's default representation. Digest helpers hash the projection,
never the source document's incidental indentation or key order.

AI packages and working sync use explicit ledger records, but their plans are
separate. An AI producer derives a deterministic artifact plan from the source
revision, AI profile, and contract version. A sync producer derives its asset
plan from the proposed revision, `workingSet`/`rawArchiveOptIn` asset policy,
and contract version. The relevant plan digest is part of that document and of
any required disclosure binding. Every required plan slot and every optional
requested slot has one stable ID/class and exactly one disposition:

- `included`: requires a safe relative path, SHA-256, positive byte count, and
  media type; it cannot carry an exclusion/failure reason;
- `excluded`, `skipped`, `unavailable`, or `failed`: requires a stable reason
  code and cannot pretend to have included bytes.

There is no silent omission within a bound plan: the validator requires the
relevant v1 AI-profile or sync-asset-policy slots and requires exactly one
ledger record for every slot. A missing artifact remains a record with
`unavailable`/`failed` and a stable reason. IDs and included paths are unique
within each document.

## AI Room Package

The AI package binds one `packageID` to one source revision, profile,
disclosure review, deterministic artifact-plan digest, exact selected-artifact
digest, and complete artifact ledger. The review must be `approved` and must
repeat the source revision's manifest digest, artifact-plan digest, and
selected-artifact digest. Pending, rejected, wrong-revision, changed-plan, or
stale/replayed reviews are invalid for every profile.

`aiReady` is the bounded default. It rejects included raw RGB sequences, raw
depth, raw confidence, diagnostics, and any other Complete-only raw class.
Selected reviewed reference images are a separate artifact class and are not
reclassified as raw capture.

`complete` may include those raw classes only when the already-required
approved disclosure record also confirms precise GPS exclusion and explicitly
records accepted raw evidence disclosure. Complete is not a permission to add
arbitrary fields or unreviewed evidence. A world map is not an AI-package
artifact in either profile.

Precise GPS has no v1 AI-package field or artifact class. Injecting a GPS key is
an unknown-key failure even when the profile is Complete.

Slice 3 realizes this contract with a dynamic, source-bound artifact plan.
Repeated classes use distinct stable slots: six canonical views derive from
the confirmed/manual canonical cameras; provider-neutral, ChatGPT, Claude, and
Grok instructions occupy four separate slots; and selected reference imagery
is bounded to four images for AI-ready or eight for Complete. AI-ready plans
structurally omit raw RGB/depth/confidence/diagnostic slots rather than merely
marking raw bytes excluded. Complete may plan available raw slots, but the
approval bit must exactly match whether any raw artifact is actually included.

The builder freezes a full ledger before final approval. The canonical
manifest binds source revision, profile, package ID, ordered plan and plan
digest, selected-artifact digest, disclosure review, and every disposition.
The deterministic ZIP32 STORE writer re-reads frozen sources, writes the
archive into an owned lease, then independently extracts it into a separate
empty owned directory. A package is not shareable unless canonical manifest
bytes, source/profile binding, exact archive-entry closure, and every included
path/digest/byte count all revalidate. Staging and the final share lease remain
outside the authoritative source package.

Final local/Simulator verification exercised that independent extraction
closure for both AI-ready and Complete. The finalized package can authenticate
Concept provenance only through its exact locally validated canonical manifest
and complete view ledger; this is integrity/provenance authentication, not an
account or provider-authentication feature.

## Concept Set

`roomscan-concept-set-v1` is additive companion state for one exact immutable
source revision. Its source binding repeats project, revision,
coordinate-space epoch, revision-manifest digest, and semantic digest. Loose
imports contain exactly one app-re-encoded attachment and no source-package
claim. Packaged imports require a source AI-package identity; any automatic
canonical mapping additionally requires that authenticated finalized-package
binding and a camera ID declared both by that package and by the current source
orientation. Without that evidence the import remains manual or unmatched;
image-content confidence is never invented.

The Concept archive extractor enforces portable flat attachment paths, strict
entry/size/CRC/digest closure, byte-verified JPEG/PNG media, no links or remote
references, and exact source binding. The app performs a second safe image
decode/re-encode before atomic marker-owned promotion into
`LocalRoomConceptStore`. Review updates are atomic and may change only mapping,
approval, and comments; source identity, provenance, and attachment identity
remain immutable. Archive/unarchive/delete target only the selected Concept
Set and never write captured room truth.

## Working-project sync

The v1 operation appends one proposed immutable revision against an explicit
`expectedHostedHeadRevisionID`. Project IDs must agree, the proposed revision
must differ from the expected head, and the only conflict policy is:

```text
preserveBranchesRequireUserResolution
```

There is no last-writer-wins or automatic-merge value.

The default `workingSet` policy accepts normalized semantics, lineage,
selected posed images, usable meshes/textures, concepts, comments, and the
assets required for supported recovery/publishing/export. Included raw RGB,
depth, confidence, or diagnostics are invalid.

Its deterministic v1 asset plan therefore carries explicit ledger slots for
`normalizedSemantics`, `revisionLineage`, `selectedReferenceImage`, `mesh`,
`texture`, `conceptAttachment`, and `comments`. `rawArchiveOptIn` carries the
same recoverable slots plus explicit `rawRGB`, `rawDepth`, `rawConfidence`,
`diagnostics`, and `worldMap` slots. A non-included slot still records its
reason; changing policy changes the plan digest.

`rawArchiveOptIn` is a distinct explicit policy. Included raw evidence requires
an approved raw-archive disclosure record that confirms precise GPS exclusion
and raw-evidence acceptance. The policy is an outbound contract, not a setting
that causes Slice 0 to enumerate or upload local capture sidecars.

## Capture quality report

`roomscan-quality-report-v1` is the one canonical, provider-neutral quality
record for a newly created immutable capture revision. `qualityReport` is an
optional revision-manifest member so every legacy package and fixture continues
to decode without migration. A new report is bound while constructing a new
revision; it is never inferred onto, copied to, or used to rewrite an existing
revision.

The report contains exactly four independent records in canonical order:
visual sharpness, spatial/visual coverage, AR tracking, and semantic
identification confidence. Each record is acceptable, advisory, unavailable,
or insufficient-evidence and carries a dimension-appropriate stable reason
code. Advisory findings include bounded evidence references, confidence,
disposition, and an affected qualitative room-space region only when evidence
supports localization. Region transforms and dimensions must be finite,
positive, affine, and nonsingular. No aggregate accuracy, survey, construction,
code-compliance, or model-compliance score exists.

Every finding, report, and Save Anyway acknowledgement binds the same project,
new revision, and coordinate-space epoch. A weak or unavailable report has
`reviewRecommended`, which is advisory rather than a package-validity failure.
Persisting it requires the explicit `saveAnyway` action over the exact sorted
warning identifiers and canonical warning digest. Missing, extra, stale, or
rebound acknowledgements fail closed. Cancel, revisit, and failed saves publish
no report.

Standalone untrusted bytes use the strict canonical decoder: malformed or
duplicate/unknown members, noncanonical bytes, unsupported reason/disposition,
invalid confidence, invalid region geometry, and revision/epoch mismatch are
rejected. The `roomscan-quality-report-carrier-v1` hook binds the unchanged
canonical report and its SHA-256 for later AI-package and snapshot owners. It
does not construct an archive, upload, publish, or add a hosted dependency.

## Portal snapshot

The portal snapshot is a separate immutable document bound to one approved
source revision and an approved disclosure review over its exact manifest and
selected-asset digests. Its section and asset enums are positive allowlists
for:

- semantic layout;
- bounded web geometry/textures;
- selected images;
- floor plan and dimensions;
- quality warnings;
- approved concepts;
- constrained branding; and
- explicitly enabled `floorPlanPDF`, `approvedGalleryZIP`, or
  `aiReadyPackage` downloads.

An `aiReadyPackage` asset additionally binds the exact
`ai-room-package.json` entry digest, package ID, AI-ready profile, source
revision/manifest, artifact plan, and package selection. Publication
validation reads the actual archive through the existing bounded ZIP32 STORE
extractor, verifies outer archive digest/size, parses the exact in-archive
manifest through this strict contract validator, and proves entry closure plus
every included path/digest/byte count. A neutral filename cannot turn a
Complete/raw or private archive into an AI-ready download, and an unledgered
hidden entry invalidates the archive.

The schema has no raw RGB/depth/confidence, world map, diagnostic bundle,
private note, full revision history, precise GPS, unapproved concept, or live
project mutation field. Unknown fields are rejected recursively, including an
otherwise valid asset carrying a private `worldMap` key.

Schema allowlisting is necessary but does not establish byte safety. The later
snapshot and package builders must decode and safely re-encode supported media,
strip non-allowlisted EXIF/XMP/auxiliary metadata, reject trailing/embedded or
polyglot payloads, and construct downloadable derivatives independently. A
download never bypasses the portal or profile raw/private exclusions; a
Complete/raw package is not a portal download kind.

Portal construction in its later owning slice must start from this empty
allowlisted type and copy validated approved values. Decoding this type from a
private package or deleting known-sensitive fields from such a package is not
a conforming snapshot builder.

## Executable oracle

The focused fixture suite loads JSON files from disk through the real validator
and includes:

- one valid document for every contract kind;
- both AI profiles;
- default working sync and explicit raw-archive opt-in;
- malformed scalar/numeric data;
- duplicate top-level or nested JSON members, including escaped key aliases;
- unsupported future version and cross-kind discriminant;
- invalid artifact disposition;
- missing or duplicate required AI artifact slot;
- AI artifact-plan digest or selected-artifact digest mismatch;
- missing or duplicate required working-sync asset slot;
- working-sync asset-plan digest or selected-asset digest mismatch;
- cross-revision/coordinate-epoch mismatch;
- stale/wrong-revision disclosure approval or changed artifact selection;
- raw evidence included in AI-ready or default sync;
- world map included in either AI profile;
- precise GPS injected into an AI package;
- private/root and world-map/nested injection into a snapshot; and
- a raw/private archive disguised as a generic portal download;
- case-folded and Unicode-normalization path aliases; and
- a renamed Complete/raw archive or hidden unledgered archive entry behind an
  otherwise valid portal asset envelope.

Positive controls prove Complete plus approved disclosure can carry raw
evidence and explicit raw archive plus approved disclosure can carry raw
evidence. Complete AI-profile, `workingSet`, and `rawArchiveOptIn` plans are
positive controls. Live-guard mutations are required to make the relevant raw-
default and required-slot tests fail before the restored implementation may be
considered exercised.
