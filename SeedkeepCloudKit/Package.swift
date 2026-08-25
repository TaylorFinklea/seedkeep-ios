// swift-tools-version: 6.0
import PackageDescription

// Phase-0 spike — pure-Swift host-testable core for the Seedkeep CloudKit data layer.
// See .docs/ai/specs/2026-06-16-r1-cloudkit-data-layer-design.md for the full design.
// NOT wired into the app target yet; the app connection lands after the spike validates.
//
// Swift 5 mode on CloudKit-touching targets: CKSyncEngine delegate + CKRecord value types
// predate strict-concurrency annotation (mirrors SimmerSmithCloudKit's pattern).
let package = Package(
    name: "SeedkeepCloudKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14), // for swift test on the host without spinning a sim
    ],
    products: [
        .library(
            name: "SeedkeepCloudKit",
            targets: ["SeedkeepCloudKit"]
        ),
        .executable(
            name: "seedkeep-schema",
            targets: ["SeedkeepSchemaTool"]
        ),
    ],
    targets: [
        // Swift 5 mode: CKSyncEngine/CKRecord predate strict-concurrency.
        .target(
            name: "SeedkeepCloudKit",
            path: "Sources/SeedkeepCloudKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SeedkeepSchemaTool",
            dependencies: ["SeedkeepCloudKit"],
            path: "Sources/SeedkeepSchemaTool",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SeedkeepCloudKitTests",
            dependencies: ["SeedkeepCloudKit"],
            path: "Tests/SeedkeepCloudKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
