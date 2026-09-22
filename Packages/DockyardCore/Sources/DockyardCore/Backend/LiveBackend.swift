import ContainerAPIClient
import ContainerResource
import Foundation

/// The real backend: XPC to `container-apiserver`, via the same client
/// libraries the `container` CLI uses.
///
/// This is the only type that knows upstream model shapes. Everything it
/// returns is a Dockyard value type, and everything it throws is a
/// `DockyardError`.
public struct LiveBackend: ContainerBackend {
    private let client = ContainerClient()
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
