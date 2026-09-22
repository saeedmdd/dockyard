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
