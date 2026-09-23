// swift-tools-version: 6.2
import PackageDescription

// Pinned to the apple/container release this app is built against. Bumping this
// is its own task: the XPC protocol must match the installed container-apiserver.
let containerVersion: Version = "1.4.1"
let containerizationVersion: Version = "0.45.0"

let package = Package(
    name: "DockyardCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DockyardCore", targets: ["DockyardCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: containerVersion),
        .package(url: "https://github.com/apple/containerization.git", exact: containerizationVersion),
        // Already in the graph via the two above; declared so `FilePath` can be
        // used directly when bridging upstream paths to `URL`.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Compose files. Already in the resolved graph at 6.2.2 by way of
        // apple/container, which does not re-export it — declaring it here adds
        // no checkout and cannot introduce a version conflict.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
    ],
    targets: [
        .target(
            name: "DockyardCore",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "TerminalProgress", package: "container"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // ContainerizationError has no product of its own; it ships
                // inside the Containerization library.
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DockyardCoreTests",
            dependencies: ["DockyardCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DockyardIntegrationTests",
            dependencies: ["DockyardCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
