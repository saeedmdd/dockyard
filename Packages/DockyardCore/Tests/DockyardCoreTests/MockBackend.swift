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
        var detail = 0
        var inspect = 0
        var logHandles = 0
        var stats = 0
        var pull = 0
        var imageDetail = 0
        var imageInspect = 0
        var deleteImage = 0
        var tagImage = 0
        var createContainer = 0
        var exec = 0
        var listVolumes = 0
        var createVolume = 0
        var deleteVolume = 0
        var volumeUsage = 0
        var listNetworks = 0
        var createNetwork = 0
        var deleteNetwork = 0
        var logIn = 0
        var logOut = 0
        var push = 0
        var saveImages = 0
        var loadImages = 0
        var diskUsage = 0
        var kernelInfo = 0
        var prune = 0
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
    private var _logFiles: [String: URL] = [:]
    private var _volumes: [VolumeItem] = []
    private var _volumeUsage: [String: UInt64] = [:]
    private var _networks: [NetworkItem] = []
    private var _logins: [RegistryLogin] = []
    private var _loadResult: [String] = []
    private var _pullProgress: [PullProgress] = []
    private var _pullFailure: DockyardError?
    private var _createProgress: [PullProgress] = []
    private var _createdCount = 0
    private var _diskUsage: DiskUsage = .stub()
    private var _kernel: KernelInfo = .stub()
    /// Names a prune reports as failures, to exercise a partial sweep.
    private var _prunePartialFailures: [String] = []

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

    func setDiskUsage(_ usage: DiskUsage) {
        lock.withLock { _diskUsage = usage }
    }

    func setPrunePartialFailures(_ failures: [String]) {
        lock.withLock { _prunePartialFailures = failures }
    }

    var currentImages: [ImageItem] {
        lock.withLock { _images }
    }

    var currentVolumes: [VolumeItem] {
        lock.withLock { _volumes }
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

    func diskUsage() async throws -> DiskUsage {
        try lock.withLock {
            _calls.diskUsage += 1
            if let _failure { throw _failure }
            return _diskUsage
        }
    }

    func kernelInfo() async throws -> KernelInfo {
        try lock.withLock {
            _calls.kernelInfo += 1
            if let _failure { throw _failure }
            return _kernel
        }
    }

    /// Prunes its own state the way the live backend prunes the runtime's, so
    /// store tests see real before/after counts rather than a canned result.
    func prune(_ target: PruneTarget) async throws -> PruneResult {
        // Gated like the lifecycle calls so a test can hold a prune open and
        // observe the in-flight state instead of racing it.
        await waitIfGated()
        return try lock.withLock {
            _calls.prune += 1
            if let _failure { throw _failure }
            let failures = _prunePartialFailures
            var removed = 0
            var reclaimed: UInt64 = 0
            switch target {
            case .containers:
                let doomed = _containers.filter { $0.status == .stopped && !failures.contains($0.id) }
                removed = doomed.count
                reclaimed = UInt64(doomed.count) * 1_000_000
                _containers.removeAll { doomed.contains($0) }
            case .images:
                let inUse = Set(_containers.map(\.image))
                let doomed = _images.filter {
                    !inUse.contains($0.reference) && !$0.isInfrastructure && !failures.contains($0.reference)
                }
                removed = doomed.count
                reclaimed = UInt64(doomed.count) * 5_000_000
                _images.removeAll { doomed.contains($0) }
            case .volumes:
                let doomed = _volumes.filter { !failures.contains($0.name) }
                removed = doomed.count
                reclaimed = UInt64(doomed.count) * 2_000_000
                _volumes.removeAll { doomed.contains($0) }
            }
            return PruneResult(
                target: target,
                removedCount: removed,
                reclaimedBytes: reclaimed,
                failures: failures.map { "\($0): in use" }
            )
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

    func containerDetail(id: String) async throws -> ContainerDetail {
        try lock.withLock {
            _calls.detail += 1
            if let _failure { throw _failure }
            guard let container = _containers.first(where: { $0.id == id }) else {
                throw DockyardError.upstream(code: "notFound", message: "container not found: \(id)")
            }
            return .stub(id: container.id, status: container.status)
        }
    }

    func containerInspectJSON(id: String) async throws -> String {
        try lock.withLock {
            _calls.inspect += 1
            if let _failure { throw _failure }
            guard _containers.contains(where: { $0.id == id }) else {
                throw DockyardError.upstream(code: "notFound", message: "container not found: \(id)")
            }
            return "{\n  \"id\" : \"\(id)\"\n}"
        }
    }

    /// Counters advance on each call so consecutive readings produce real
    /// rates: 0.5 cores of CPU and 1 KB/s of network per second of interval.
    func containerStats(id: String) async throws -> RawContainerStats {
        try lock.withLock {
            _calls.stats += 1
            if let _failure { throw _failure }
            guard _containers.contains(where: { $0.id == id }) else {
                throw DockyardError.upstream(code: "notFound", message: "no such container \(id)")
            }
            let tick = UInt64(_calls.stats)
            return RawContainerStats(
                id: id,
                memoryUsedBytes: 64 * 1024 * 1024,
                memoryLimitBytes: 1024 * 1024 * 1024,
                cpuUsageMicroseconds: tick * 500_000,
                networkReceivedBytes: tick * 1024,
                networkSentBytes: tick * 512,
                blockReadBytes: tick * 4096,
                blockWrittenBytes: tick * 2048,
                processCount: 3
            )
        }
    }

    /// Backed by a real temp file so tailing behaves as it does in the app.
    func logHandles(id: String) async throws -> ContainerLogHandles {
        try lock.withLock {
            _calls.logHandles += 1
            if let _failure { throw _failure }
            guard let url = _logFiles[id] else {
                throw DockyardError.upstream(code: "notFound", message: "no logs for \(id)")
            }
            return ContainerLogHandles(stdio: try FileHandle(forReadingFrom: url), boot: nil)
        }
    }

    func setPullProgress(_ progress: [PullProgress]) {
        lock.withLock { _pullProgress = progress }
    }

    func setPullFailure(_ error: DockyardError?) {
        lock.withLock { _pullFailure = error }
    }

    func pullImage(reference: String, platform: String?) -> AsyncThrowingStream<PullProgress, any Error> {
        let (updates, failure) = lock.withLock { () -> ([PullProgress], DockyardError?) in
            _calls.pull += 1
            return (_pullProgress, _pullFailure)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for update in updates {
                    try? await Task.sleep(for: .milliseconds(5))
                    if Task.isCancelled { break }
                    continuation.yield(update)
                }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    func imageDetail(reference: String) async throws -> ImageDetail {
        try lock.withLock {
            _calls.imageDetail += 1
            if let _failure { throw _failure }
            guard let image = _images.first(where: { $0.reference == reference }) else {
                throw DockyardError.upstream(code: "notFound", message: "image not found: \(reference)")
            }
            return ImageDetail(
                reference: image.reference,
                displayReference: image.displayReference,
                digest: image.digest,
                mediaType: image.mediaType,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                variants: [
                    ImageVariant(
                        platform: "linux/arm64", digest: image.digest, sizeBytes: 7_000_000,
                        entrypoint: ["/entrypoint.sh"], command: ["sh"], workingDirectory: "/",
                        user: "root", environment: ["PATH": "/usr/bin"], labels: [:], stopSignal: nil
                    ),
                    ImageVariant(
                        platform: "linux/amd64", digest: "sha256:beef", sizeBytes: 7_500_000,
                        entrypoint: [], command: ["sh"], workingDirectory: nil,
                        user: nil, environment: [:], labels: [:], stopSignal: "SIGQUIT"
                    ),
                ]
            )
        }
    }

    func imageInspectJSON(reference: String) async throws -> String {
        try lock.withLock {
            _calls.imageInspect += 1
            if let _failure { throw _failure }
            return "{\n  \"name\" : \"\(reference)\"\n}"
        }
    }

    @discardableResult
    func deleteImage(reference: String) async throws -> ImageDeletionResult {
        try lock.withLock {
            _calls.deleteImage += 1
            if let _failure { throw _failure }
            guard let image = _images.first(where: { $0.reference == reference }) else {
                throw DockyardError.upstream(code: "notFound", message: "image not found")
            }
            if image.isInfrastructure {
                throw DockyardError.upstream(
                    code: "invalidArgument",
                    message: "This image is used by the container runtime itself and cannot be deleted."
                )
            }
            _images.removeAll { $0.reference == reference }
            return ImageDeletionResult(reference: reference, reclaimedBytes: 4_000_000)
        }
    }

    func tagImage(reference: String, newReference: String) async throws {
        try lock.withLock {
            _calls.tagImage += 1
            if let _failure { throw _failure }
            guard let image = _images.first(where: { $0.reference == reference }) else {
                throw DockyardError.upstream(code: "notFound", message: "image not found")
            }
            _images.append(
                ImageItem(
                    reference: newReference, displayReference: newReference,
                    digest: image.digest, mediaType: image.mediaType, isInfrastructure: false
                )
            )
        }
    }

    func setCreateProgress(_ progress: [PullProgress]) {
        lock.withLock { _createProgress = progress }
    }

    func createContainer(spec: RunSpec) -> AsyncThrowingStream<CreateProgress, any Error> {
        let (updates, failure, id) = lock.withLock { () -> ([PullProgress], DockyardError?, String) in
            _calls.createContainer += 1
            _createdCount += 1
            return (_createProgress, _failure, "created-\(_createdCount)")
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                for update in updates {
                    try? await Task.sleep(for: .milliseconds(5))
                    if Task.isCancelled { break }
                    continuation.yield(.working(update))
                }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else {
                    self.lock.withLock {
                        self._containers.append(.stub(id: id, status: .stopped))
                    }
                    continuation.yield(.created(id: id))
                    continuation.finish()
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    func exec(_ request: ExecRequest) async throws -> any ExecSessionHandle {
        try lock.withLock {
            _calls.exec += 1
            if let _failure { throw _failure }
            guard let container = _containers.first(where: { $0.id == request.containerID }) else {
                throw DockyardError.upstream(code: "notFound", message: "no such container")
            }
            guard container.status == .running else {
                throw DockyardError.upstream(
                    code: "invalidState",
                    message: "The container isn’t running, so there’s nothing to open a shell in."
                )
            }
            return MockExecSession()
        }
    }

    func execCapturing(containerID: String, command: [String]) async throws -> (output: String, exitCode: Int32) {
        try lock.withLock {
            _calls.exec += 1
            if let _failure { throw _failure }
            return (command.joined(separator: " "), 0)
        }
    }

    func setVolumes(_ volumes: [VolumeItem]) {
        lock.withLock { _volumes = volumes }
    }

    func setVolumeUsage(_ usage: [String: UInt64]) {
        lock.withLock { _volumeUsage = usage }
    }

    func listVolumes() async throws -> [VolumeItem] {
        try lock.withLock {
            _calls.listVolumes += 1
            if let _failure { throw _failure }
            return _volumes.sorted { $0.name < $1.name }
        }
    }

    @discardableResult
    func createVolume(_ spec: VolumeSpec) async throws -> VolumeItem {
        try lock.withLock {
            _calls.createVolume += 1
            if let _failure { throw _failure }
            if _volumes.contains(where: { $0.name == spec.trimmedName }) {
                throw DockyardError.upstream(code: "exists", message: "volume already exists")
            }
            let volume = VolumeItem.stub(name: spec.trimmedName)
            _volumes.append(volume)
            return volume
        }
    }

    func deleteVolume(name: String) async throws {
        try lock.withLock {
            _calls.deleteVolume += 1
            if let _failure { throw _failure }
            guard _volumes.contains(where: { $0.name == name }) else {
                throw DockyardError.upstream(code: "notFound", message: "no such volume")
            }
            _volumes.removeAll { $0.name == name }
        }
    }

    func volumeDiskUsage(name: String) async throws -> UInt64 {
        try lock.withLock {
            _calls.volumeUsage += 1
            if let _failure { throw _failure }
            return _volumeUsage[name] ?? 0
        }
    }

    func setNetworks(_ networks: [NetworkItem]) {
        lock.withLock { _networks = networks }
    }

    func listNetworks() async throws -> [NetworkItem] {
        try lock.withLock {
            _calls.listNetworks += 1
            if let _failure { throw _failure }
            return _networks.sorted { $0.name < $1.name }
        }
    }

    @discardableResult
    func createNetwork(_ spec: NetworkSpec) async throws -> NetworkItem {
        try lock.withLock {
            _calls.createNetwork += 1
            if let _failure { throw _failure }
            if _networks.contains(where: { $0.name == spec.trimmedName }) {
                throw DockyardError.upstream(code: "exists", message: "network already exists")
            }
            let network = NetworkItem.stub(name: spec.trimmedName, mode: spec.mode)
            _networks.append(network)
            return network
        }
    }

    func deleteNetwork(name: String) async throws {
        try lock.withLock {
            _calls.deleteNetwork += 1
            if let _failure { throw _failure }
            guard let network = _networks.first(where: { $0.name == name }) else {
                throw DockyardError.upstream(code: "notFound", message: "no such network")
            }
            if network.isBuiltin {
                throw DockyardError.upstream(
                    code: "invalidArgument",
                    message: "The default network is used by the container runtime and cannot be deleted."
                )
            }
            _networks.removeAll { $0.name == name }
        }
    }

    func setLogins(_ logins: [RegistryLogin]) {
        lock.withLock { _logins = logins }
    }

    func setLoadResult(_ references: [String]) {
        lock.withLock { _loadResult = references }
    }

    func listRegistryLogins() throws -> [RegistryLogin] {
        try lock.withLock {
            if let _failure { throw _failure }
            return _logins.sorted { $0.hostname < $1.hostname }
        }
    }

    func logIn(_ credentials: RegistryCredentials, scheme: RegistryScheme) async throws {
        try lock.withLock {
            _calls.logIn += 1
            if let _failure { throw _failure }
            _logins.removeAll { $0.hostname == credentials.trimmedHostname }
            _logins.append(
                RegistryLogin(
                    hostname: credentials.trimmedHostname,
                    username: credentials.trimmedUsername,
                    createdAt: Date(),
                    modifiedAt: Date()
                )
            )
        }
    }

    func logOut(hostname: String) throws {
        try lock.withLock {
            _calls.logOut += 1
            if let _failure { throw _failure }
            guard _logins.contains(where: { $0.hostname == hostname }) else {
                throw DockyardError.upstream(code: "notFound", message: "not signed in")
            }
            _logins.removeAll { $0.hostname == hostname }
        }
    }

    func pushImage(reference: String, platform: String?, scheme: RegistryScheme) -> AsyncThrowingStream<PullProgress, any Error> {
        let (updates, failure) = lock.withLock { () -> ([PullProgress], DockyardError?) in
            _calls.push += 1
            return (_pullProgress, _pullFailure)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for update in updates {
                    try? await Task.sleep(for: .milliseconds(5))
                    if Task.isCancelled { break }
                    continuation.yield(update)
                }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    func saveImages(references: [String], to destination: URL) async throws {
        try lock.withLock {
            _calls.saveImages += 1
            if let _failure { throw _failure }
        }
        try Data("archive".utf8).write(to: destination)
    }

    @discardableResult
    func loadImages(from source: URL) async throws -> [String] {
        try lock.withLock {
            _calls.loadImages += 1
            if let _failure { throw _failure }
            return _loadResult
        }
    }

    func setLogFile(_ url: URL, for id: String) {
        lock.withLock { _logFiles[id] = url }
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

extension ContainerDetail {
    static func stub(id: String = "web", status: ContainerStatus = .running) -> ContainerDetail {
        ContainerDetail(
            id: id,
            image: "docker.io/library/nginx:latest",
            status: status,
            startedAt: status == .running ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            executable: "/docker-entrypoint.sh",
            arguments: ["nginx", "-g", "daemon off;"],
            environment: ["PATH": "/usr/local/sbin:/usr/bin", "NGINX_VERSION": "1.27"],
            workingDirectory: "/",
            user: "0:0",
            hasTerminal: false,
            cpus: 4,
            memoryInBytes: 1024 * 1024 * 1024,
            os: "linux",
            architecture: "arm64",
            runtimeHandler: "container-runtime-linux",
            isVirtualizationEnabled: false,
            isRosettaEnabled: false,
            isReadOnlyRootFilesystem: false,
            ports: [PortMapping(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, networkProtocol: "tcp")],
            networks: [
                NetworkAttachment(network: "default", hostname: id, ipv4Address: "192.168.64.3", gateway: "192.168.64.1")
            ],
            mounts: [
                MountInfo(kind: .virtiofs, source: "/", destination: "/", isReadOnly: false),
                MountInfo(kind: .virtiofs, source: "/Users/test/site", destination: "/usr/share/nginx/html", isReadOnly: true),
                MountInfo(kind: .volume, source: "cache", destination: "/var/cache", isReadOnly: false, volumeName: "cache"),
            ],
            dnsNameservers: ["192.168.64.1"],
            dnsDomain: "test",
            dnsSearchDomains: [],
            labels: ["app": "web"]
        )
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
        networks: [NetworkAttachment] = [],
        startedAt: Date? = nil
    ) -> ContainerItem {
        ContainerItem(
            id: id,
            image: image,
            status: status,
            startedAt: startedAt ?? (status == .running ? Date(timeIntervalSince1970: 1_700_000_000) : nil),
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
        digest: String = "sha256:0123456789abcdef0123456789abcdef",
        isInfrastructure: Bool = false
    ) -> ImageItem {
        ImageItem(
            reference: reference,
            displayReference: displayReference,
            digest: digest,
            mediaType: "application/vnd.oci.image.index.v1+json",
            isInfrastructure: isInfrastructure
        )
    }
}

/// An exec session that simply echoes whatever it is sent.
final class MockExecSession: ExecSessionHandle, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private(set) var lastSize: (columns: Int, rows: Int)?
    private(set) var isClosed = false

    init() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        output = stream
        self.continuation = continuation
    }

    func send(_ data: Data) async {
        continuation.yield(data)
    }

    func resize(columns: Int, rows: Int) async {
        lock.withLock { lastSize = (columns, rows) }
    }

    func waitForExit() async -> Int32 { 0 }

    func close() async {
        lock.withLock { isClosed = true }
        continuation.finish()
    }
}

extension VolumeItem {
    static func stub(name: String = "data") -> VolumeItem {
        VolumeItem(
            name: name,
            driver: "local",
            format: "ext4",
            source: "/Users/test/Library/Application Support/com.apple.container/volumes/\(name)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            labels: [:],
            options: [:],
            sizeInBytes: nil
        )
    }
}

extension NetworkItem {
    static func stub(
        name: String = "default",
        mode: NetworkItem.Mode = .nat,
        isBuiltin: Bool = false
    ) -> NetworkItem {
        NetworkItem(
            name: name,
            mode: mode,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            subnet: "192.168.64.0/24",
            gateway: "192.168.64.1",
            isBuiltin: isBuiltin,
            labels: [:]
        )
    }
}

extension DiskUsage {
    static func stub(
        images: ResourceUsage = ResourceUsage(
            total: 9, active: 3, sizeInBytes: 1_200_000_000, reclaimableBytes: 800_000_000
        ),
        containers: ResourceUsage = ResourceUsage(
            total: 6, active: 2, sizeInBytes: 40_000_000, reclaimableBytes: 25_000_000
        ),
        volumes: ResourceUsage = ResourceUsage(
            total: 2, active: 1, sizeInBytes: 500_000_000, reclaimableBytes: 100_000_000
        )
    ) -> DiskUsage {
        DiskUsage(images: images, containers: containers, volumes: volumes)
    }
}

extension KernelInfo {
    static func stub() -> KernelInfo {
        KernelInfo(
            path: "/Library/Application Support/com.apple.container/kernel/vmlinux",
            architecture: "arm64",
            os: "linux",
            arguments: ["console=hvc0", "tsc=reliable", "panic=0"]
        )
    }
}
