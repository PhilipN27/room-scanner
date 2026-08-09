# RoomScanStudio head-revision export format

Status: Phase-5 source contract, host-statically checked on 2026-08-09. This is
an inspectable handoff of one current head revision, not a backup and not a
full-history archive. No ZIP/PDF/PNG/share consumer has run on this Windows
host.

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

## Share lease and proof gates

Each external handoff lease has a fixed-schema regular `lease-ownership.json`
marker. Cleanup and startup reconciliation act only on marker-valid,
non-symlink direct lease children; lookalikes and symbolic links are preserved.
The finalized lease remains alive through `UIActivityViewController` completion
or cancellation. A cleanup failure stays actionable and is never replaced by a
broad scratch-root deletion.

Still required on macOS/iOS: Xcode compilation, portable XCTest and app/UI test
execution, independent ZIP reader/Files/Archive Utility inspection, manifest
and digest verification, PNG/PDF rendering, native USDZ inspection when
present, and iPhone/iPad system-share completion/cancel and lease-recovery
behavior.
