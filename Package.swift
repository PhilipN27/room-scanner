// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoomScanCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "RoomScanCore",
            targets: ["RoomScanCore"]
        )
    ],
    targets: [
        .target(
            name: "RoomScanCore",
            path: "RoomScanCore/Sources/RoomScanCore"
        ),
        .testTarget(
            name: "RoomScanCoreTests",
            dependencies: ["RoomScanCore"],
            path: "RoomScanCore/Tests/RoomScanCoreTests",
            exclude: ["Fixtures"]
        )
    ]
)
