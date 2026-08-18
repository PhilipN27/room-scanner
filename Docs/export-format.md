# RoomScanStudio local export and interchange formats

Status: Phase-5 legacy head export plus Slice 3 AI Room Package and Concept Set
local formats. The legacy format below is an inspectable handoff of one current
head revision, not a backup or full-history archive; Slice 3 does not
reinterpret or replace it.

## Scope and source boundary

`materializeHeadForExport(projectID:expectedHeadRevisionID:into:)` reloads and
validates the authoritative package under its same-process lock, requires the
exact head revision, then deep-copies a frozen snapshot to an external owned
workspace. It never exposes package URLs to the app export UI.

The snapshot contains only:

- `metadata.json`, the head `revision.json`, `semantic-model.json`,
  `annotations.json`, `measurements.json`, and `photos.json`;
- the referenced project thumbnail and reference photos;
- declared, validated present evidence, including native USDZ when present;
- validated regular attachments needed by the head; and
- `source-map.json`, which records whether each original relative reference was
  project-root or revision-root scoped.

It excludes the project manifest, all earlier revisions, pending/ownership
records, package-local exports, and unreferenced files. Exported metadata,
revision, and photos documents rewrite asset references to static archive paths
and every rewritten reference must resolve to exactly one exported entry.

## Archive profile

The final file is classic ZIP32 with STORE (no compression). Archive entry
paths are app-owned strict ASCII names; user-controlled package paths are never
used as ZIP names. The profile uses UTF-8 flag `0x0800`, fixed DOS timestamp
1980-01-01, fixed file attributes, no directory records, extras, comments, data
descriptors, encryption, or ZIP64. Entries are bytewise sorted and the writer
uses a never-existing owned `.partial` path before its final atomic promotion.

The final archive permits at most 4096 entries. Two required derived entries
(floor-plan PNG and PDF) and `manifest.json` are app-owned reservations, so
store materialization permits at most 4093 entries. The pre-manifest archive
may therefore contain at most 4095 entries. The writer preflights each bounded
stream for CRC-32, lowercase SHA-256, and size, writes a second bounded pass
while requiring the same values, and structurally inspects local and central
records before promotion. The manifest and final ZIP deliberately do not hash
themselves.

Other profile caps are path length at most 255 UTF-8 bytes, at most 1 GiB per
entry, at most 2 GiB total ZIP bytes, at most 512 MiB aggregate derived output,
PNG at most 4096 by 4096 and 64 MiB, and PDF at most 32 pages and 64 MiB.

## Manifest and output statuses

`manifest.json` lists every non-manifest entry once with media type, byte count,
and lowercase SHA-256. Its integrity scope is
`allEntriesExceptManifest`; it records the project/revision source IDs and a
complete, unique requested-output status/reason record for canonical JSON,
thumbnail, photos, every evidence kind, attachments, derived output, and each
unsupported format.

Native USDZ is included byte-for-byte only when the validated evidence plan
declares it present. Deterministic fixture omissions and unavailable/not-
requested raw mesh, world map, and provenance report explicit stable skips.
GLB, OBJ, and PLY always report stable skipped reasons in Phase 5 because no
verified converter is bundled. UIKit-derived output consists only of a semantic
top-down floor-plan PNG and a one-page PDF summary; these are not captured mesh,
survey, or cross-SDK byte-determinism claims.

## AI Room Package v1

`roomscan-ai-room-package-v1` is a distinct provider-neutral ZIP32 STORE
profile. `manifest.json` is canonical JSON and binds one immutable source
revision, AI-ready or Complete profile, deterministic ordered artifact plan and
digest, exact selected-artifact digest, approved disclosure review, and one
ledger entry for every planned artifact. Included entries carry a portable
relative path, media type, positive byte count, and SHA-256; excluded, skipped,
unavailable, or failed entries carry only a stable reason. No unledgered entry
is allowed.

AI-ready structurally has no raw RGB/depth/confidence/diagnostic slots, world
map, or precise-GPS field. Complete may include planned available raw evidence
only when the exact review accepts it; it still has no world map or precise
GPS. Both profiles include or explicitly account for semantics, lineage,
orientation, floor plan, six canonical views, selected references, materials,
quality carrier, brief/intent, four instruction variants, and optional
geometry/texture slots. Package construction reads immutable source bytes but
never writes the source package.

The archive permits at most 4,096 entries, 1 GiB per entry, 2 GiB total, and an
8 MiB manifest. A freshly written archive remains unshareable until a separate
extractor reopens it in an empty owned directory and proves canonical manifest
identity, source/profile binding, exact entry closure, and every included
digest/byte count. The outer receipt records archive SHA-256, byte count, CRC,
and per-entry digests. Final local/Simulator verification independently closed
this extraction path for both AI-ready and Complete; it does not replace the
physical Share Sheet/import protocol.

## Concept Set v1 packaged-import profile

Slice 3 does not export or write a Concept ZIP: this is an import-only
interchange profile. It accepts an externally produced `roomscan-concept-set-v1`
import containing one canonical `manifest.json` plus flat
`attachments/<stable-id>.(jpg|jpeg|png)` entries. The accepted profile permits
at most 65 entries, 32 MiB per entry, 512 MiB total/uncompressed, and a 1 MiB
manifest. Import rejects traversal, absolute/backslash paths, links,
path-identity aliases, nested/hidden entries, corrupt CRC/digests, unsupported
media, remote references, wrong source binding, and incomplete closure. The
iOS boundary then decodes and re-encodes every accepted image and recomputes
media type, path, digest, and size before atomic Concept-store promotion.
Source room bytes remain unchanged.

## Share lease and proof gates

Each external handoff lease has a fixed-schema regular `lease-ownership.json`
marker. Cleanup and startup reconciliation act only on marker-valid,
non-symlink direct lease children; lookalikes and symbolic links are preserved.
The finalized lease remains alive through `UIActivityViewController` completion
or cancellation. A cleanup failure stays actionable and is never replaced by a
broad scratch-root deletion.

The final local/Simulator matrix proves the scoped one-shot lease cleanup and
the deterministic archive closure, but not a real system handoff. Files,
AirDrop, third-party activity behavior, physical security-scoped import, native
USDZ consumer behavior, and system-share completion/cancel/error/dismissal
lifetime still require the physical-device protocol. Physical iPad is waived
and remains unverified.
