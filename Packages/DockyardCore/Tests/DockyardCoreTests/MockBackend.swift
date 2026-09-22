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
        var start = 0
        var stop = 0
        var kill = 0
        var delete = 0
    }

    /// Records what was asked of each container, in order.
    struct Invocation: Sendable, Equatable {
        var id: String
        var action: String
        var detail: String?
    }

    private let lock = NSLock()
    private var _calls = Calls()
    private var _containers: [ContainerItem]
    private var _images: [ImageItem]
    private var _health: DaemonHealth
    private var _failure: DockyardError?
    private var _sizes: [String: Int64]
    private var _invocations: [Invocation] = []

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

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    var currentContainers: [ContainerItem] {
        lock.withLock { _containers }
    }

    func setFailure(_ failure: DockyardError?) {
        lock.withLock { _failure = failure }
    }

    func setContainers(_ containers: [ContainerItem]) {
        lock.withLock { _containers = containers }
    }

    /// Holds lifecycle calls open so a test can observe the in-flight state
    /// instead of racing it.
    private var _gate: CheckedContinuation<Void, Never>?
    private var _isGated = false
    private var _gateReached: CheckedContinuation<Void, Never>?

    func gateLifecycleCalls() {
        lock.withLock { _isGated = true }
    }

    /// Suspends until a gated call has actually started.
    func waitForGatedCall() async {
        await withCheckedContinuation { continuation in
            lock.withLock { _gateReached = continuation }
        }
    }

    func releaseGate() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            _isGated = false
            defer { _gate = nil }
            return _gate
        }
        continuation?.resume()
    }

    private func waitIfGated() async {
        let gated = lock.withLock { _isGated }
        guard gated else { return }
        await withCheckedContinuation { continuation in
            let reached = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                _gate = continuation
                defer { _gateReached = nil }
                return _gateReached
            }
            reached?.resume()
        }
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

    // MARK: - Lifecycle

    /// These mutate the stored containers so a store's refresh after an action
    /// sees the change, exactly as it would against a real daemon.
    func startContainer(id: String) async throws {
        await waitIfGated()
        try lock.withLock {
            _calls.start += 1
            _invocations.append(.init(id: id, action: "start", detail: nil))
            if let _failure { throw _failure }
            replace(id: id) { $0.withStatus(.running) }
        }
    }

    func stopContainer(id: String) async throws {
        try lock.withLock {
            _calls.stop += 1
            _invocations.append(.init(id: id, action: "stop", detail: nil))
            if let _failure { throw _failure }
            replace(id: id) { $0.withStatus(.stopped) }
        }
    }

    func killContainer(id: String, signal: ProcessSignal) async throws {
        try lock.withLock {
            _calls.kill += 1
            _invocations.append(.init(id: id, action: "kill", detail: signal.rawValue))
            if let _failure { throw _failure }
            replace(id: id) { $0.withStatus(.stopped) }
        }
    }

    func deleteContainer(id: String, force: Bool) async throws {
        try lock.withLock {
            _calls.delete += 1
            _invocations.append(.init(id: id, action: "delete", detail: force ? "force" : nil))
            if let _failure { throw _failure }
            guard let existing = _containers.first(where: { $0.id == id }) else { return }
            if existing.status == .running && !force {
                throw DockyardError.upstream(code: "invalidState", message: "container is running")
            }
            _containers.removeAll { $0.id == id }
        }
    }

    private func replace(id: String, transform: (ContainerItem) -> ContainerItem) {
        guard let index = _containers.firstIndex(where: { $0.id == id }) else { return }
        _containers[index] = transform(_containers[index])
    }
}

extension ContainerItem {
    func withStatus(_ status: ContainerStatus) -> ContainerItem {
        ContainerItem(
            id: id,
            image: image,
            status: status,
            startedAt: status == .running ? Date() : nil,
            createdAt: createdAt,
            os: os,
            architecture: architecture,
            cpus: cpus,
            memoryInBytes: memoryInBytes,
            ports: ports,
            networks: networks,
            labels: labels
        )
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
