import Foundation

@testable import DockyardCore

/// In-memory `ContainerBackend` for tests.
///
/// Every call can be made to throw, and every call is counted, so stores can be
/// tested for refresh behaviour and error routing without a running daemon.
final class MockBackend: ContainerBackend, @unchecked Sendable {
    struct Calls: Sendable, Equatable {
        var health = 0
        var listContainers = 0
        var listImages = 0
        var imageSize = 0
    }

    private let lock = NSLock()
    private var _calls = Calls()
    private var _containers: [ContainerItem]
    private var _images: [ImageItem]
    private var _health: DaemonHealth
    private var _failure: DockyardError?
    private var _sizes: [String: Int64]

    init(
        containers: [ContainerItem] = [],
        images: [ImageItem] = [],
        health: DaemonHealth = .stub(),
        sizes: [String: Int64] = [:],
        failure: DockyardError? = nil
    ) {
        _containers = containers
        _images = images
        _health = health
        _sizes = sizes
        _failure = failure
    }

    var calls: Calls {
        lock.withLock { _calls }
    }

    /// The health this backend answers with, for tests that need to compare
    /// against the exact value.
    var stubbedHealth: DaemonHealth {
        lock.withLock { _health }
    }

    func setFailure(_ failure: DockyardError?) {
        lock.withLock { _failure = failure }
    }

    func setContainers(_ containers: [ContainerItem]) {
        lock.withLock { _containers = containers }
    }

    // MARK: - ContainerBackend

    func health() async throws -> DaemonHealth {
        try lock.withLock {
            _calls.health += 1
            if let _failure { throw _failure }
            return _health
        }
    }

    func listContainers() async throws -> [ContainerItem] {
        try lock.withLock {
            _calls.listContainers += 1
            if let _failure { throw _failure }
            return _containers
        }
    }

    func listImages() async throws -> [ImageItem] {
        try lock.withLock {
            _calls.listImages += 1
            if let _failure { throw _failure }
            return _images
        }
    }

    func imageSize(reference: String) async throws -> Int64 {
        try lock.withLock {
            _calls.imageSize += 1
            if let _failure { throw _failure }
            return _sizes[reference] ?? 0
        }
    }
}

// MARK: - Fixtures

extension DaemonHealth {
    static func stub(version: String = DockyardCore.linkedContainerVersion) -> DaemonHealth {
        DaemonHealth(
            apiServerVersion: version,
            apiServerCommit: "ee848e3abcdef",
            apiServerBuild: "release",
            appName: "container-apiserver",
            appRoot: URL(fileURLWithPath: "/Users/test/Library/Application Support/com.apple.container"),
            installRoot: URL(fileURLWithPath: "/usr/local"),
            logRoot: URL(fileURLWithPath: "/var/log/container")
        )
    }
}

extension ContainerItem {
    static func stub(
        id: String = "web",
        image: String = "docker.io/library/nginx:latest",
        status: ContainerStatus = .running,
        ports: [PortMapping] = [],
        networks: [NetworkAttachment] = []
    ) -> ContainerItem {
        ContainerItem(
            id: id,
            image: image,
            status: status,
            startedAt: status == .running ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            os: "linux",
            architecture: "arm64",
            cpus: 4,
            memoryInBytes: 1024 * 1024 * 1024,
            ports: ports,
            networks: networks,
            labels: [:]
        )
    }
}

extension ImageItem {
    static func stub(
        reference: String = "docker.io/library/alpine:3.20",
        displayReference: String = "alpine:3.20",
        isInfrastructure: Bool = false
    ) -> ImageItem {
        ImageItem(
            reference: reference,
            displayReference: displayReference,
            digest: "sha256:0123456789abcdef0123456789abcdef",
            mediaType: "application/vnd.oci.image.index.v1+json",
            isInfrastructure: isInfrastructure
        )
    }
}
