// swift-tools-version: 6.2
import PackageDescription

// Pinned to the apple/container release this app is built against. Bumping this
// is its own task: the XPC protocol must match the installed container-apiserver.
let containerVersion: Version = "1.0.0"
let containerizationVersion: Version = "0.33.3"

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
    ],
    targets: [
        .target(
            name: "DockyardCore",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                // ContainerizationError has no product of its own; it ships
                // inside the Containerization library.
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
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
