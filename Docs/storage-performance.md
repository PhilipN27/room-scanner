# Storage and performance

Authoritative room data is an append-only local package. SwiftData is a small,
rebuildable local index with `groupContainer: .none` and
`cloudKitDatabase: .none`; it never owns scan assets.

Capture, export, and backup use marker-owned scratch directories, bounded
streaming copies, atomic promotion, and scoped cleanup/retry. Phase 5 exports
only the immutable head revision. Phase 6 snapshots full project history only
after explicit opt-in and Back up. Both reject links, special files, unsafe
paths, and configured byte/entry caps before promotion.

The source-enforced export limits are 4,096 final ZIP entries, 4,093
materialized source entries (two required derived entries and one manifest are
reserved), 255 UTF-8 bytes per archive path, 1 GiB per entry, 2 GiB per
archive, and 64 MiB each for derived PNG and PDF. Full-project backup limits
are 4,096 final entries, 4,095 package entries plus its manifest, 255-byte
package paths, 256 MiB per package file, 512 MiB archive/uncompressed total,
and an 8 MiB backup manifest. These are safety bounds, not measured performance
claims.

Slice 3 keeps materialization, image rendering/sanitization, hashing, archive
construction, and finalization outside SwiftUI bodies and capture callbacks;
`RoomAIRoomPackageAppService` dispatches expensive preparation away from the
main actor. Inputs are frozen into marker-owned export staging, the finished
archive is independently extracted/validated, and share completion or retry
removes only the exact owned lease. Concept imports use a separate marker-owned
scratch root and same-root atomic promotion into a separate Concept store;
cancellation or failure publishes no Concept Set.

The completed local/Simulator matrix exercised deterministic AI-ready and
Complete extraction/closure, exact finalized-package Concept mapping, and
scoped Share Sheet lease cleanup. It is not a throughput, peak-memory, thermal,
or physical system-share measurement.

The AI Room Package uses the ZIP defaults of 4,096 entries, 1 GiB per entry,
2 GiB total, and an 8 MiB manifest cap. A Concept archive permits at most 65
entries, 32 MiB per entry, 512 MiB total/uncompressed, and a 1 MiB manifest.
The app image sanitizer admits at most 32 MiB encoded input, 8,192 pixels on
either axis, and 24 million decoded pixels; the portable Concept media
validator caps decoded pixels at 40 million. Reference selection considers at
most 64 candidates and selects at most four for AI-ready or eight for
Complete. Complete inventory groups permit at most 64 raw RGB, depth,
confidence, or diagnostic identifiers each. Materialization bounds one RGB
file to 32 MiB, depth to 64 MiB, confidence to 16 MiB, and mesh evidence to
128 MiB. These are rejection limits, not a measured memory budget.

The pending device protocol records disk free space before/after, elapsed time,
peak-memory/thermal state, and scoped scratch cleanup after success, failure,
and cancellation. Exercise representative small and large room assets on each
physical test device before establishing a release performance expectation.

Performance, disk pressure, large USDZ/CKAsset behavior, UIKit image output,
Vision analyzer latency, archive/import throughput, and system-share lifetime
remain physical-device gates. Simulator/local results do not establish
sustained throughput, peak memory, thermal behavior, or real Share Sheet
lifetime.
