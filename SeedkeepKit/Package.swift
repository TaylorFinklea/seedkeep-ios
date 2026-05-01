// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SeedkeepKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14), // for swift-test on the host without spinning a sim
    ],
    products: [
        .library(
            name: "SeedkeepKit",
            targets: ["SeedkeepKit"]
        ),
    ],
    targets: [
        .target(
            name: "SeedkeepKit",
            path: "Sources/SeedkeepKit"
        ),
        .testTarget(
            name: "SeedkeepKitTests",
            dependencies: ["SeedkeepKit"],
            path: "Tests/SeedkeepKitTests"
        ),
    ]
)
