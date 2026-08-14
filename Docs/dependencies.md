# Dependencies

The root Swift package has no third-party dependency. `RoomScanCore` uses
Foundation plus the standard `simd` module for portable vector math, and
remains portable across its declared macOS 13/iOS 17 targets. It does not import
Apple UI, capture, cloud, or persistence frameworks. The iOS app uses Apple
frameworks at isolated boundaries: SwiftUI, SwiftData local indexing,
RoomPlan/ARKit capture, RealityKit non-AR viewing, UIKit export/share, and
CloudKit private backup transport.

The iOS app target has one intentionally pinned remote Swift package:
[`MetalSplatter`](https://github.com/scier/MetalSplatter) at revision
`2b965de1934de38dda1c71cf90bf798aa948a14c`. Its committed Xcode workspace
resolution also pins its current transitive packages: `spz-swift` 2.1.0 at
`e2410c91bceba2539c11157ad92e488ef6e16416` and
`swift-argument-parser` 1.8.2 at
`6a52f3251125d74daf04fcbd5e6f08a75d074382`. The structural verifier permits
only that exact MetalSplatter URL and revision and checks those resolved pins;
it does not generally allow remote packages.

No ZIP library, analytics SDK, login SDK, converter, or server dependency is
included. ZIPFoundation was considered earlier but is not used; the bounded
classic ZIP32 STORE implementation is in-repository Foundation code. Future
converters or sync dependencies require license, offline-scope, privacy,
artifact-inspection, and platform proof review before adoption.
