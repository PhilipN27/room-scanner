# Dependencies

The root Swift package has no third-party dependency. `RoomScanCore` imports
Foundation only and remains portable across its declared macOS 13/iOS 17
targets. The iOS app uses Apple frameworks at isolated boundaries: SwiftUI,
SwiftData local indexing, RoomPlan/ARKit capture, RealityKit non-AR viewing,
UIKit export/share, and CloudKit private backup transport.

No ZIP library, analytics SDK, login SDK, converter, server dependency, remote
Swift package, or `Package.resolved` is included. ZIPFoundation was considered
earlier but is not used; the bounded classic ZIP32 STORE implementation is
in-repository Foundation code. Future converters or sync dependencies require
license, offline-scope, privacy, artifact-inspection, and platform proof review
before adoption.
