// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindowKeeper",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure logic — display keys, window matching, placement, snapshot merging — kept
        // free of AppKit and Accessibility so it can be tested with synthetic displays.
        .target(name: "WindowKeeperKit"),
        .executableTarget(name: "WindowKeeper", dependencies: ["WindowKeeperKit"]),
        .testTarget(name: "WindowKeeperKitTests", dependencies: ["WindowKeeperKit"]),
    ]
)
