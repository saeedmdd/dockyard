import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging

/// The real backend: XPC to `container-apiserver`, via the same client
/// libraries the `container` CLI uses.
///
/// This is the only type that knows upstream model shapes. Everything it
/// returns is a Dockyard value type, and everything it throws is a
/// `DockyardError`.
public struct LiveBackend: ContainerBackend {
    /// A fresh client per call, which is what the CLI does.
    ///
    /// `ContainerClient` holds a reusable XPC connection, and a command-line
    /// tool makes one and exits. An app outlives the daemon: after a `system
    /// stop` and `start` from the System panel, a client made before the stop
    /// answered `list` with an **empty array** rather than an error, so the
    /// Containers screen said "No containers yet" while the CLI listed six, and
    /// only relaunching the app fixed it. The image and volume calls were
    /// unaffected because upstream exposes those as statics that build a client
    /// each time.
    private var client: ContainerClient { ContainerClient() }
    private let configLoader = SystemConfigLoader()

    public init() {}

    // MARK: - System

    public func health() async throws -> DaemonHealth {
        try await mapErrors {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
            return DaemonHealth(
                apiServerVersion: health.apiServerVersion,
                apiServerCommit: health.apiServerCommit,
                apiServerBuild: health.apiServerBuild,
                appName: health.apiServerAppName,
                appRoot: health.appRoot,
                installRoot: health.installRoot,
                logRoot: health.logRoot.map { URL(fileURLWithPath: $0.string) }
            )
        }
    }

    public func diskUsage() async throws -> DiskUsage {
        try await mapErrors {
            let stats = try await ClientDiskUsage.get()
            return DiskUsage(
                images: ResourceUsage(stats.images),
                containers: ResourceUsage(stats.containers),
                volumes: ResourceUsage(stats.volumes)
            )
        }
    }

    public func kernelInfo() async throws -> KernelInfo {
        try await mapErrors {
            // The runtime keeps one kernel per platform, and the only platform
            // it runs containers on is this Mac's own architecture under Linux.
            let kernel = try await ClientKernel.getDefaultKernel(for: .linuxArm)
            return KernelInfo(
                path: kernel.path.path,
                architecture: kernel.platform.architecture.rawValue,
                os: kernel.platform.os.rawValue,
                arguments: kernel.kernelArgs
            )
        }
    }

    public func prune(_ target: PruneTarget) async throws -> PruneResult {
        switch target {
        case .containers: try await pruneContainers()
        case .images: try await pruneImages()
        case .volumes: try await pruneVolumes()
        }
    }

    /// Mirrors `container prune`: every stopped container, machines excluded.
    private func pruneContainers() async throws -> PruneResult {
        try await mapErrors {
            let stopped = try await client.list(
                filters: ContainerListFilters(status: .stopped).withoutMachines()
            )
            var removed = 0
            var reclaimed: UInt64 = 0
            var failures: [String] = []
            for container in stopped {
                do {
                    // Asked before the delete, because afterwards there is
                    // nothing left to measure.
                    let size = try await client.diskUsage(id: container.id)
                    try await client.delete(id: container.id)
                    removed += 1
                    reclaimed += size
                } catch {
                    failures.append("\(container.id): \(DockyardError(mapping: error).shortReason)")
                }
            }
            return PruneResult(
                target: .containers,
                removedCount: removed,
                reclaimedBytes: reclaimed,
                failures: failures
            )
        }
    }

    /// Mirrors `container image prune --all`, minus the runtime's own images.
    private func pruneImages() async throws -> PruneResult {
        try await mapErrors {
            let config = try await configLoader.load()
            let images = try await ClientImage.list()
            let inUse = Set(
                try await client.list(filters: ContainerListFilters.all)
                    .map(\.configuration.image.reference)
            )
            let unused = images.filter { image in
                guard !inUse.contains(image.reference) else { return false }
                // Upstream's `--all` does not make this exception, so it can
                // delete the builder and init images out from under itself and
                // leave the next build to re-pull them. Dockyard keeps them.
                return !Utility.isInfraImage(
                    name: image.reference,
                    builderImage: config.build.image,
                    initImage: config.vminit.image
                )
            }

            var removed = 0
            var failures: [String] = []
            for image in unused {
                do {
                    try await ClientImage.delete(reference: image.reference, garbageCollect: false)
                    removed += 1
                } catch {
                    failures.append("\(image.reference): \(DockyardError(mapping: error).shortReason)")
                }
            }
            // Untagging is what the loop above does; the space only comes back
            // when the layers nothing points at any more are collected.
            let (_, reclaimed) = try await ClientImage.cleanUpOrphanedBlobs()
            return PruneResult(
                target: .images,
                removedCount: removed,
                reclaimedBytes: reclaimed,
                failures: failures
            )
        }
    }

    /// Mirrors `container volume prune`.
    private func pruneVolumes() async throws -> PruneResult {
        try await mapErrors {
            let volumes = try await ClientVolume.list()
            let inUse = Set(
                try await client.list(filters: ContainerListFilters.all)
                    .flatMap(\.configuration.mounts)
                    .compactMap { $0.isVolume ? $0.volumeName : nil }
            )
            var removed = 0
            var reclaimed: UInt64 = 0
            var failures: [String] = []
            for volume in volumes where !inUse.contains(volume.name) {
                do {
                    let size = try await ClientVolume.volumeDiskUsage(name: volume.name)
                    try await ClientVolume.delete(name: volume.name)
                    removed += 1
                    reclaimed += size
                } catch {
                    failures.append("\(volume.name): \(DockyardError(mapping: error).shortReason)")
                }
            }
            return PruneResult(
                target: .volumes,
                removedCount: removed,
                reclaimedBytes: reclaimed,
                failures: failures
            )
        }
    }

    // MARK: - Containers

    public func listContainers() async throws -> [ContainerItem] {
        try await mapErrors {
            // `.withoutMachines()` matches `container list`: machine VMs are an
            // implementation detail of the runtime, not user containers.
            let snapshots = try await client.list(filters: ContainerListFilters.all.withoutMachines())
            return snapshots
                .map(ContainerItem.init(snapshot:))
                .sorted { $0.id < $1.id }
        }
    }

    public func containerDetail(id: String) async throws -> ContainerDetail {
        try await mapErrors {
            ContainerDetail(snapshot: try await client.get(id: id))
        }
    }

    public func containerInspectJSON(id: String) async throws -> String {
        try await mapErrors {
            let snapshot = try await client.get(id: id)
            // `container inspect` serialises the managed resource, so the same
            // wrapper is used here and the output lines up with the CLI's.
            // Qualified: upstream has its own `ContainerStatus`, and inside this
            // module the bare name means Dockyard's enum.
            let managed = ManagedContainer(
                configuration: snapshot.configuration,
                status: ContainerResource.ContainerStatus(
                    state: snapshot.status,
                    networks: snapshot.networks,
                    startedDate: snapshot.startedDate
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(managed)
            return String(decoding: data, as: UTF8.self)
        }
    }

    public func containerStats(id: String) async throws -> RawContainerStats {
        try await mapErrors {
            let stats = try await client.stats(id: id)
            return RawContainerStats(
                id: stats.id,
                memoryUsedBytes: stats.memoryUsageBytes,
                memoryLimitBytes: stats.memoryLimitBytes,
                cpuUsageMicroseconds: stats.cpuUsageUsec,
                networkReceivedBytes: stats.networkRxBytes,
                networkSentBytes: stats.networkTxBytes,
                blockReadBytes: stats.blockReadBytes,
                blockWrittenBytes: stats.blockWriteBytes,
                processCount: stats.numProcesses
            )
        }
    }

    public func exec(_ request: ExecRequest) async throws -> any ExecSessionHandle {
        try await mapErrors {
            let container = try await client.get(id: request.containerID)
            guard container.status == .running else {
                throw DockyardError.upstream(
                    code: "invalidState",
                    message: "The container isn’t running, so there’s nothing to open a shell in."
                )
            }

            let shell = try await firstAvailableShell(
                in: container,
                candidates: request.shellCandidates
            )

            // Starting from the container's own init process is what upstream's
            // exec does, and it matters: the image's PATH and other variables
            // come with it, so the shell can find its own binaries.
            var configuration = container.configuration.initProcess
            configuration.executable = shell
            configuration.arguments = []
            configuration.terminal = request.allocateTerminal

            let stdin = Pipe()
            let stdout = Pipe()
            // With a terminal the runtime merges stderr into stdout; asking for
            // a separate stderr would leave a pipe nobody ever writes to.
            let stderr: Pipe? = request.allocateTerminal ? nil : Pipe()

            let process = try await client.createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: configuration,
                stdio: [
                    stdin.fileHandleForReading,
                    stdout.fileHandleForWriting,
                    stderr?.fileHandleForWriting,
                ]
            )

            let session = LiveExecSession(process: process, stdin: stdin, stdout: stdout, stderr: stderr)
            try await process.start()
            if request.allocateTerminal {
                await session.resize(columns: request.columns, rows: request.rows)
            }
            return session
        }
    }

    public func execCapturing(
        containerID: String,
        command: [String]
    ) async throws -> (output: String, exitCode: Int32) {
        try await mapErrors {
            let container = try await client.get(id: containerID)
            guard let executable = command.first else {
                throw DockyardError.other("No command to run.")
            }

            var configuration = container.configuration.initProcess
            configuration.executable = executable
            configuration.arguments = Array(command.dropFirst())
            // No terminal: stdout and stderr stay separate and nothing tries to
            // interpret escape sequences.
            configuration.terminal = false

            let stdout = Pipe()
            let stderr = Pipe()
            let process = try await client.createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: configuration,
                stdio: [nil, stdout.fileHandleForWriting, stderr.fileHandleForWriting]
            )

            let collector = OutputBox()
            stdout.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }

            try await process.start()
            let exitCode = try await process.wait()

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // Whatever was written between the last callback and exit.
            collector.append((try? stdout.fileHandleForReading.readToEnd()) ?? Data())
            collector.append((try? stderr.fileHandleForReading.readToEnd()) ?? Data())

            return (collector.text, exitCode)
        }
    }

    /// Picks the first shell that actually exists in the image.
    ///
    /// Minimal images routinely have only `/bin/sh`, and asking for bash in one
    /// of those fails with an error that says nothing about shells.
    private func firstAvailableShell(
        in container: ContainerSnapshot,
        candidates: [String]
    ) async throws -> String {
        guard candidates.count > 1 else {
            return candidates.first ?? "/bin/sh"
        }
        for candidate in candidates {
            var probe = container.configuration.initProcess
            probe.executable = "/bin/sh"
            probe.arguments = ["-c", "test -x \(candidate)"]
            probe.terminal = false
            guard
                let process = try? await client.createProcess(
                    containerId: container.id,
                    processId: UUID().uuidString.lowercased(),
                    configuration: probe,
                    stdio: [nil, nil, nil]
                )
            else { continue }
            try? await process.start()
            if let status = try? await process.wait(), status == 0 {
                return candidate
            }
        }
        return candidates.last ?? "/bin/sh"
    }

    /// The plugin `container network create` defaults to.
    private static let defaultNetworkPlugin = "container-network-vmnet"

    // MARK: - Registry

    /// Maps the app's choice onto upstream's, which is what `--scheme` takes.
    private static func requestScheme(_ scheme: RegistryScheme) -> RequestScheme {
        switch scheme {
        case .auto: .auto
        case .https: .https
        case .http: .http
        }
    }

    /// The same keychain service the `container` CLI uses, so logins made in
    /// either place are visible to both.
    private var keychain: KeychainHelper {
        KeychainHelper(securityDomain: Constants.keychainID)
    }

    public func listRegistryLogins() throws -> [RegistryLogin] {
        do {
            return try keychain.list()
                .map {
                    RegistryLogin(
                        hostname: $0.hostname,
                        username: $0.username,
                        createdAt: $0.createdDate,
                        modifiedAt: $0.modifiedDate
                    )
                }
                .sorted { $0.hostname < $1.hostname }
        } catch {
            throw DockyardError(mapping: error)
        }
    }

    public func logIn(_ credentials: RegistryCredentials, scheme requested: RegistryScheme) async throws {
        try await mapErrors {
            let config = try await configLoader.load()
            // `docker.io` is written `registry-1.docker.io` in a credential
            // store; resolving here means a user can type what they know.
            let host = Reference.resolveDomain(domain: credentials.trimmedHostname)
            let scheme = try Self.requestScheme(requested).schemeFor(
                host: host,
                internalDnsDomain: config.dns.domain
            )

            // Checked before saving: storing a credential that does not work
            // turns a clear failure now into a confusing one at push time.
            let authentication = BasicAuthentication(
                username: credentials.trimmedUsername,
                password: credentials.password
            )
            let client = RegistryClient(
                host: host,
                scheme: scheme.rawValue,
                authentication: authentication
            )
            try await client.ping()

            try keychain.save(
                hostname: host,
                username: credentials.trimmedUsername,
                password: credentials.password
            )
        }
    }

    public func logOut(hostname: String) throws {
        do {
            let host = Reference.resolveDomain(domain: hostname)
            // The keychain's delete succeeds silently when nothing matches, so
            // signing out of something that was never signed in would report
            // success. Checked first, so the answer is truthful either way.
            guard try keychain.list().contains(where: { $0.hostname == host }) else {
                throw DockyardError.upstream(
                    code: "notFound",
                    message: "You’re not signed in to \(hostname)."
                )
            }
            try keychain.delete(hostname: host)
        } catch {
            throw DockyardError(mapping: error)
        }
    }

    public func pushImage(reference: String, platform: String?, scheme: RegistryScheme) -> AsyncThrowingStream<PullProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = try await configLoader.load()
                    let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
                    let accumulator = ProgressAccumulator { continuation.yield($0) }
                    // As with pull, the runtime reports sizes but never names
                    // the phase, so the phase is set here.
                    accumulator.setPhase(description: "Pushing image", itemsName: "blobs")

                    try await image.push(
                        platform: try Self.resolvePlatform(platform),
                        scheme: Self.requestScheme(scheme),
                        containerSystemConfig: config,
                        progressUpdate: accumulator.handler
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: DockyardError(mapping: error))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    public func saveImages(references: [String], to destination: URL) async throws {
        try await mapErrors {
            let config = try await configLoader.load()
            try await ClientImage.save(
                references: references,
                out: destination.path,
                platform: nil,
                containerSystemConfig: config
            )
        }
    }

    @discardableResult
    public func loadImages(from source: URL) async throws -> [String] {
        try await mapErrors {
            let result = try await ClientImage.load(from: source.path, force: false)
            return result.images.map(\.reference)
        }
    }

    // MARK: - Networks

    public func listNetworks() async throws -> [NetworkItem] {
        try await mapErrors {
            try await NetworkClient().list()
                .map(NetworkItem.init(resource:))
                .sorted { $0.name < $1.name }
        }
    }

    @discardableResult
    public func createNetwork(_ spec: NetworkSpec) async throws -> NetworkItem {
        try await mapErrors {
            try Utility.validEntityName(spec.trimmedName)
            let subnet = spec.trimmedSubnet.isEmpty ? nil : try CIDRv4(spec.trimmedSubnet)
            let configuration = try NetworkConfiguration(
                name: spec.trimmedName,
                mode: spec.mode == .nat ? .nat : .hostOnly,
                ipv4Subnet: subnet,
                labels: try ResourceLabels(
                    Dictionary(
                        spec.labels.filter { !$0.isEmpty }.map { ($0.key, $0.value) },
                        uniquingKeysWith: { _, last in last }
                    )
                ),
                // The same default `container network create` uses; naming it
                // here keeps the app's networks identical to the CLI's.
                plugin: Self.defaultNetworkPlugin
            )
            return NetworkItem(resource: try await NetworkClient().create(configuration: configuration))
        }
    }

    public func deleteNetwork(name: String) async throws {
        try await mapErrors {
            // The runtime needs its built-in network; removing it would break
            // every container, so it is refused with a reason rather than left
            // to fail somewhere deeper.
            if let network = try? await NetworkClient().get(id: name), network.isBuiltin {
                throw DockyardError.upstream(
                    code: "invalidArgument",
                    message: "The default network is used by the container runtime and cannot be deleted."
                )
            }
            try await NetworkClient().delete(id: name)
        }
    }

    // MARK: - Volumes

    public func listVolumes() async throws -> [VolumeItem] {
        try await mapErrors {
            try await ClientVolume.list()
                .map(VolumeItem.init(configuration:))
                .sorted { $0.name < $1.name }
        }
    }

    @discardableResult
    public func createVolume(_ spec: VolumeSpec) async throws -> VolumeItem {
        try await mapErrors {
            // Validated with the runtime's own rule rather than only the
            // sheet's, so the two can never disagree.
            try Utility.validEntityName(spec.trimmedName)
            let configuration = try await ClientVolume.create(
                name: spec.trimmedName,
                driver: spec.driver,
                driverOpts: Dictionary(
                    spec.options.filter { !$0.isEmpty }.map { ($0.key, $0.value) },
                    uniquingKeysWith: { _, last in last }
                ),
                labels: Dictionary(
                    spec.labels.filter { !$0.isEmpty }.map { ($0.key, $0.value) },
                    uniquingKeysWith: { _, last in last }
                )
            )
            return VolumeItem(configuration: configuration)
        }
    }

    public func deleteVolume(name: String) async throws {
        try await mapErrors {
            try await ClientVolume.delete(name: name)
        }
    }

    public func volumeDiskUsage(name: String) async throws -> UInt64 {
        try await mapErrors {
            try await ClientVolume.volumeDiskUsage(name: name)
        }
    }

    public func logHandles(id: String) async throws -> ContainerLogHandles {
        try await mapErrors {
            // Upstream's order, as `container logs` relies on it: index 0 is
            // the container's stdio, index 1 is the VM boot log.
            let handles = try await client.logs(id: id)
            guard let stdio = handles.first else {
                throw DockyardError.upstream(
                    code: "invalidState",
                    message: "The runtime returned no log files for this container."
                )
            }
            return ContainerLogHandles(stdio: stdio, boot: handles.count > 1 ? handles[1] : nil)
        }
    }

    public func createContainer(spec: RunSpec) -> AsyncThrowingStream<CreateProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = try await configLoader.load()
                    // Same two steps the CLI takes, in the same order: mint an
                    // id from the requested name, then validate it with the
                    // runtime's own rule rather than a guess at it.
                    let id = Utility.createContainerID(name: spec.trimmedName.isEmpty ? nil : spec.trimmedName)
                    try Utility.validEntityName(id)

                    let flags = try spec.toFlags()
                    let accumulator = ProgressAccumulator { progress in
                        continuation.yield(.working(progress))
                    }

                    // Does the heavy lifting: resolves the platform, fetches
                    // and unpacks the image if absent, fetches the kernel, and
                    // builds the configuration — applying exactly the
                    // validation `container run` applies.
                    let (configuration, kernel, initImage) = try await Utility.containerConfigFromFlags(
                        id: id,
                        image: spec.image.trimmingCharacters(in: .whitespacesAndNewlines),
                        arguments: spec.commandArguments,
                        process: flags.process,
                        management: flags.management,
                        resource: flags.resource,
                        registry: flags.registry,
                        imageFetch: flags.imageFetch,
                        containerSystemConfig: config,
                        progressUpdate: accumulator.handler,
                        log: Self.log
                    )

                    try Task.checkCancellation()

                    try await client.create(
                        configuration: configuration,
                        options: ContainerCreateOptions(autoRemove: spec.removeWhenStopped),
                        kernel: kernel,
                        initImage: initImage
                    )
                    continuation.yield(.created(id: id))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: DockyardError(mapping: error))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    /// Upstream's APIs take a `Logger`; nothing in the app reads it, so it goes
    /// nowhere rather than to the app's stderr.
    private static let log = Logger(label: "com.saeedmdd.Dockyard", factory: { _ in SwiftLogNoOpLogHandler() })

    public func startContainer(id: String) async throws {
        try await mapErrors {
            let container = try await client.get(id: id)
            // Starting an already-running container is a no-op rather than an
            // error: the user may have clicked twice, or a poll may have raced.
            guard container.status != .running else { return }

            // A missing bind-mount source fails deep inside the runtime with an
            // opaque error, so check first and say something useful.
            for mount in container.configuration.mounts where mount.isVirtiofs {
                guard FileManager.default.fileExists(atPath: mount.source) else {
                    throw DockyardError.upstream(
                        code: "invalidState",
                        message: "The folder \(mount.source) is mounted into this container but no longer exists."
                    )
                }
            }

            do {
                // Detached with no terminal: every stdio slot is nil. Upstream's
                // `ProcessIO` is deliberately not used — with `detach: true` it
                // produces exactly this, and on the way installs readability
                // handlers on the *app's* stdin and stdout, which an app must
                // not have done to it.
                let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
                try await process.start()
            } catch {
                // Bootstrap leaves the container half-up on failure; upstream's
                // start command does the same cleanup.
                try? await client.stop(id: id)
                throw error
            }
        }
    }

    public func stopContainer(id: String) async throws {
        try await mapErrors {
            try await client.stop(id: id, opts: .default)
        }
    }

    public func killContainer(id: String, signal: ProcessSignal) async throws {
        try await mapErrors {
            try await client.kill(id: id, signal: signal.rawValue)
        }
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        try await mapErrors {
            try await client.delete(id: id, force: force)
        }
    }

    // MARK: - Images

    public func listImages() async throws -> [ImageItem] {
        try await mapErrors {
            let config = try await configLoader.load()
            let images = try await ClientImage.list()
            return
                images
                .map { image in
                    ImageItem(
                        reference: image.reference,
                        displayReference: (try? ClientImage.denormalizeReference(
                            image.reference,
                            containerSystemConfig: config
                        )) ?? image.reference,
                        digest: image.digest,
                        mediaType: image.description.mediaType,
                        isInfrastructure: Utility.isInfraImage(
                            name: image.reference,
                            builderImage: config.build.image,
                            initImage: config.vminit.image
                        )
                    )
                }
                .sorted { $0.displayReference < $1.displayReference }
        }
    }

    public func pullImage(reference: String, platform: String?) -> AsyncThrowingStream<PullProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = try await configLoader.load()
                    // Turns what the user typed into what the registry expects:
                    // "alpine" becomes "docker.io/library/alpine:latest".
                    let normalized = try ClientImage.normalizeReference(reference, containerSystemConfig: config)
                    let resolvedPlatform = try Self.resolvePlatform(platform)

                    let accumulator = ProgressAccumulator { progress in
                        continuation.yield(progress)
                    }

                    // The runtime reports sizes and counts but never names the
                    // phase: `container image pull` sets these strings on its
                    // own progress bar rather than receiving them from the
                    // server. Without doing the same, every pull would read
                    // "Starting…" from beginning to end.
                    accumulator.setPhase(description: "Fetching image", itemsName: "blobs")

                    let image = try await ClientImage.pull(
                        reference: normalized,
                        platform: resolvedPlatform,
                        scheme: .auto,
                        containerSystemConfig: config,
                        progressUpdate: accumulator.handler
                    )

                    try Task.checkCancellation()

                    // Unpacking is not optional: `container image pull` does it
                    // too, and an image that has only been fetched cannot be
                    // run. Skipping it would leave the user with a row in the
                    // list that fails the moment they use it.
                    accumulator.setPhase(description: "Unpacking image", itemsName: "entries")
                    try await image.unpack(platform: resolvedPlatform, progressUpdate: accumulator.handler)

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: DockyardError(mapping: error))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    /// Resolves a platform string, falling back to this machine's.
    private static func resolvePlatform(_ platform: String?) throws -> ContainerizationOCI.Platform? {
        guard let platform, !platform.isEmpty else { return nil }
        return try ContainerizationOCI.Platform(from: platform)
    }

    public func imageDetail(reference: String) async throws -> ImageDetail {
        try await mapErrors {
            let config = try await configLoader.load()
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            // The same conversion `container image inspect` uses, so the pane
            // and the CLI describe an image identically.
            let resource = try await image.toImageResource(containerSystemConfig: config)
            return ImageDetail(resource: resource, image: image)
        }
    }

    public func imageInspectJSON(reference: String) async throws -> String {
        try await mapErrors {
            let config = try await configLoader.load()
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            let resource = try await image.toImageResource(containerSystemConfig: config)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try encoder.encode(resource), as: UTF8.self)
        }
    }

    @discardableResult
    public func deleteImage(reference: String) async throws -> ImageDeletionResult {
        try await mapErrors {
            let config = try await configLoader.load()
            // The runtime needs these to run at all; upstream's delete skips
            // them silently, which would leave a user wondering why nothing
            // happened. Refusing with a reason is better.
            if Utility.isInfraImage(
                name: reference,
                builderImage: config.build.image,
                initImage: config.vminit.image
            ) {
                throw DockyardError.upstream(
                    code: "invalidArgument",
                    message: "This image is used by the container runtime itself and cannot be deleted."
                )
            }

            try await ClientImage.delete(reference: reference, garbageCollect: false)
            // Deleting a reference does not free its layers; upstream collects
            // them afterwards and reports what that actually reclaimed.
            let (_, reclaimed) = try await ClientImage.cleanUpOrphanedBlobs()
            return ImageDeletionResult(reference: reference, reclaimedBytes: reclaimed)
        }
    }

    public func tagImage(reference: String, newReference: String) async throws {
        try await mapErrors {
            let config = try await configLoader.load()
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            let normalized = try ClientImage.normalizeReference(newReference, containerSystemConfig: config)
            _ = try await image.tag(new: normalized)
        }
    }

    public func imageSize(reference: String) async throws -> Int64 {
        try await mapErrors {
            let config = try await configLoader.load()
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            return try await ClientImage.getFullImageSize(image: image)
        }
    }

    // MARK: - Error handling

    /// Runs `body`, translating any upstream failure into a `DockyardError` and
    /// dropping cached configuration when the daemon turns out to be gone, so a
    /// restarted server is not served stale settings.
    private func mapErrors<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let mapped = DockyardError(mapping: error)
            if mapped.isDaemonDown {
                await configLoader.invalidate()
            }
            throw mapped
        }
    }
}

// MARK: - Upstream → Dockyard conversions

extension ContainerItem {
    init(snapshot: ContainerSnapshot) {
        let configuration = snapshot.configuration
        self.init(
            id: snapshot.id,
            image: configuration.image.reference,
            status: ContainerStatus(snapshot.status),
            startedAt: snapshot.startedDate,
            createdAt: configuration.creationDate,
            os: snapshot.platform.os,
            architecture: snapshot.platform.architecture,
            cpus: configuration.resources.cpus,
            memoryInBytes: configuration.resources.memoryInBytes,
            ports: configuration.publishedPorts.map(PortMapping.init(publishPort:)),
            networks: snapshot.networks.map(NetworkAttachment.init(attachment:)),
            labels: configuration.labels
        )
    }
}

extension ContainerDetail {
    init(snapshot: ContainerSnapshot) {
        let configuration = snapshot.configuration
        let process = configuration.initProcess
        self.init(
            id: snapshot.id,
            image: configuration.image.reference,
            status: ContainerStatus(snapshot.status),
            startedAt: snapshot.startedDate,
            createdAt: configuration.creationDate,
            executable: process.executable,
            arguments: process.arguments,
            // Stored as `KEY=value` strings; a value may itself contain `=`.
            environment: Dictionary(
                process.environment.compactMap { entry -> (String, String)? in
                    guard let separator = entry.firstIndex(of: "=") else { return (entry, "") }
                    return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
                },
                uniquingKeysWith: { _, last in last }
            ),
            workingDirectory: process.workingDirectory,
            user: process.user.description,
            hasTerminal: process.terminal,
            cpus: configuration.resources.cpus,
            memoryInBytes: configuration.resources.memoryInBytes,
            os: configuration.platform.os,
            architecture: configuration.platform.architecture,
            runtimeHandler: configuration.runtimeHandler,
            isVirtualizationEnabled: configuration.virtualization,
            isRosettaEnabled: configuration.rosetta,
            isReadOnlyRootFilesystem: configuration.readOnly,
            ports: configuration.publishedPorts.map(PortMapping.init(publishPort:)),
            networks: snapshot.networks.map(NetworkAttachment.init(attachment:)),
            mounts: configuration.mounts.map(MountInfo.init(filesystem:)),
            dnsNameservers: configuration.dns?.nameservers ?? [],
            dnsDomain: configuration.dns?.domain,
            dnsSearchDomains: configuration.dns?.searchDomains ?? [],
            labels: configuration.labels
        )
    }
}

extension MountInfo {
    init(filesystem: Filesystem) {
        let kind: Kind =
            switch filesystem.type {
            case .block: .block
            case .volume: .volume
            case .virtiofs: .virtiofs
            case .tmpfs: .tmpfs
            }
        self.init(
            kind: kind,
            source: filesystem.source,
            destination: filesystem.destination,
            isReadOnly: filesystem.options.readonly,
            volumeName: filesystem.volumeName
        )
    }
}

extension ContainerStatus {
    init(_ status: RuntimeStatus) {
        self =
            switch status {
            case .running: .running
            case .stopped: .stopped
            case .stopping: .stopping
            case .unknown: .unknown
            }
    }
}

extension PortMapping {
    init(publishPort: PublishPort) {
        self.init(
            hostAddress: publishPort.hostAddress.description,
            hostPort: publishPort.hostPort,
            containerPort: publishPort.containerPort,
            networkProtocol: publishPort.proto.rawValue
        )
    }
}

extension NetworkAttachment {
    init(attachment: Attachment) {
        self.init(
            network: attachment.network,
            hostname: attachment.hostname,
            ipv4Address: attachment.ipv4Address.description,
            gateway: attachment.ipv4Gateway.description
        )
    }
}

extension ImageDetail {
    init(resource: ImageResource, image: ClientImage) {
        self.init(
            reference: resource.name,
            displayReference: resource.displayReference,
            digest: image.digest,
            mediaType: image.description.mediaType,
            createdAt: resource.configuration.creationDate,
            // Attestation manifests are metadata, not builds you can run, and
            // they arrive with the platform `unknown/unknown`. Upstream's
            // verbose listing skips them and its size calculation ignores them,
            // so listing them as platforms would both confuse and inflate the
            // reported size.
            variants: resource.variants
                .filter { $0.platform.description != ImageVariant.attestationPlatform }
                .map(ImageVariant.init(variant:))
        )
    }
}

extension ImageVariant {
    init(variant: ImageResource.Variant) {
        let config = variant.config.config
        self.init(
            platform: variant.platform.description,
            digest: variant.digest,
            sizeBytes: variant.size,
            entrypoint: config?.entrypoint ?? [],
            command: config?.cmd ?? [],
            workingDirectory: config?.workingDir,
            user: config?.user,
            // Same `KEY=value` shape as a container's environment, and the same
            // reason to split on the first `=` only.
            environment: Dictionary(
                (config?.env ?? []).compactMap { entry -> (String, String)? in
                    guard let separator = entry.firstIndex(of: "=") else { return (entry, "") }
                    return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
                },
                uniquingKeysWith: { _, last in last }
            ),
            labels: config?.labels ?? [:],
            stopSignal: config?.stopSignal
        )
    }
}

extension VolumeItem {
    init(configuration: VolumeConfiguration) {
        self.init(
            name: configuration.name,
            driver: configuration.driver,
            format: configuration.format,
            source: configuration.source,
            createdAt: configuration.creationDate,
            labels: configuration.labels,
            options: configuration.options,
            sizeInBytes: configuration.sizeInBytes
        )
    }
}

extension NetworkItem {
    init(resource: NetworkResource) {
        let configuration = resource.configuration
        self.init(
            name: resource.name,
            mode: configuration.mode == .nat ? .nat : .hostOnly,
            createdAt: resource.creationDate,
            // The subnet and gateway are assigned when the network comes up, so
            // the status is what carries them, not the configuration.
            subnet: resource.status.ipv4Subnet.description,
            gateway: resource.status.ipv4Gateway.description,
            isBuiltin: resource.isBuiltin,
            labels: configuration.labels.dictionary
        )
    }
}

extension ResourceUsage {
    /// Upstream names the last field `reclaimable`; the model spells out that
    /// it is a byte count, since the two next to it are plain counts.
    init(_ usage: ContainerAPIClient.ResourceUsage) {
        self.init(
            total: usage.total,
            active: usage.active,
            sizeInBytes: usage.sizeInBytes,
            reclaimableBytes: usage.reclaimable
        )
    }
}
