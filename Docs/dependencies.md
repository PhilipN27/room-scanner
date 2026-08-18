# Dependencies

The root Swift package has no third-party dependency. `RoomScanCore` uses
Foundation plus the standard `simd` module for portable vector math, and
remains portable across its declared macOS 13/iOS 17 targets. It does not import
Apple UI, capture, cloud, or persistence frameworks. The iOS app uses Apple
frameworks at isolated boundaries: SwiftUI, SwiftData local indexing,
RoomPlan/ARKit capture, RealityKit non-AR viewing, UIKit export/share, and
CloudKit private backup transport. Slice 3 additionally uses `ImageIO` and
`CoreGraphics` for bounded image decode/re-encode and derivatives, `Vision` for
advisory sensitive-content analysis, and `UniformTypeIdentifiers` for the
JPEG/PNG/ZIP document-picker allowlist. These are local Apple-framework
boundaries; they are not provider or hosted dependencies.

The iOS app target has one intentionally pinned remote Swift package:
[`MetalSplatter`](https://github.com/scier/MetalSplatter) at revision
`2b965de1934de38dda1c71cf90bf798aa948a14c`. Its committed Xcode workspace
resolution also pins its current transitive packages: `spz-swift` 2.1.0 at
`e2410c91bceba2539c11157ad92e488ef6e16416` and
`swift-argument-parser` 1.8.2 at
`6a52f3251125d74daf04fcbd5e6f08a75d074382`. The structural verifier permits
only that exact MetalSplatter URL and revision and checks those resolved pins;
it does not generally allow remote packages.

The Slice 3 production `AIRedesign` path adds no ZIP library, analytics SDK,
login SDK, provider/model SDK, authentication client, direct HTTP client,
converter, or server dependency. ZIPFoundation was considered earlier but is
not used; deterministic AI Room Package and Concept Set archives reuse the
bounded in-repository classic ZIP32 STORE implementation and strict extractors.
Slice 3 adds no Swift package. The scoped AIRedesign production-source scan
rejects injected network/auth clients, with an in-memory `URLSession` control
proving the detector reaches that boundary. This is not a claim that the entire
app is network-free: the separately scoped, explicit private CloudKit backup
transport remains. Future converters, hosted sync, or provider adapters require
license, offline-scope, privacy, artifact-inspection, and platform proof review
before adoption.
