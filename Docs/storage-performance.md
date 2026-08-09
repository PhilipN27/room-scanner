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

The pending device protocol records disk free space before/after, elapsed time,
peak-memory/thermal state, and scoped scratch cleanup after success, failure,
and cancellation. Exercise representative small and large room assets on each
physical test device before establishing a release performance expectation.

Performance, disk pressure, large USDZ/CKAsset behavior, UIKit PNG/PDF output,
and system-share lifetime are external macOS/device gates. The repository has
no measured throughput or memory claim from this Windows host.
