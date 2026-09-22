import Foundation

/// Runtime state of a container, mirroring upstream `RuntimeStatus` without
/// exposing it to the UI layer.
public enum ContainerStatus: String, Sendable, Codable, CaseIterable {
    case unknown
    case stopped
    case running
    case stopping

    /// True while an operation is expected to finish on its own.
    public var isTransient: Bool { self == .stopping }
}

/// A published port mapping, `hostAddress:hostPort -> containerPort/proto`.
public struct PortMapping: Sendable, Hashable, Codable, Identifiable {
    public let hostAddress: String
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let networkProtocol: String

    public var id: String { "\(hostAddress):\(hostPort)->\(containerPort)/\(networkProtocol)" }

    /// URL to open when the user clicks the mapping, for ports that plausibly
    /// serve HTTP. `nil` for UDP.
    public var localURL: URL? {
        guard networkProtocol.lowercased() == "tcp" else { return nil }
        return URL(string: "http://localhost:\(hostPort)")
    }

    public init(hostAddress: String, hostPort: UInt16, containerPort: UInt16, networkProtocol: String) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.networkProtocol = networkProtocol
    }
}

/// A network interface attached to a container.
public struct NetworkAttachment: Sendable, Hashable, Codable, Identifiable {
    public let network: String
    public let hostname: String
    public let ipv4Address: String
    public let gateway: String

    public var id: String { "\(network)/\(ipv4Address)" }

    public init(network: String, hostname: String, ipv4Address: String, gateway: String) {
        self.network = network
        self.hostname = hostname
        self.ipv4Address = ipv4Address
        self.gateway = gateway
    }
}

/// One row in the containers list.
///
/// Deliberately a plain value type: views and stores never see upstream types,
/// so the linked `apple/container` version can change without touching the UI.
public struct ContainerItem: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let image: String
    public let status: ContainerStatus
    public let startedAt: Date?
    public let createdAt: Date
    public let os: String
    public let architecture: String
    public let cpus: Int
    public let memoryInBytes: UInt64
    public let ports: [PortMapping]
    public let networks: [NetworkAttachment]
    public let labels: [String: String]

    /// First IPv4 address, which is what the list column shows.
    public var primaryIPv4: String? { networks.first?.ipv4Address }

    public init(
        id: String,
        image: String,
        status: ContainerStatus,
        startedAt: Date?,
        createdAt: Date,
        os: String,
        architecture: String,
        cpus: Int,
        memoryInBytes: UInt64,
        ports: [PortMapping],
        networks: [NetworkAttachment],
        labels: [String: String]
    ) {
        self.id = id
        self.image = image
        self.status = status
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.os = os
        self.architecture = architecture
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.ports = ports
        self.networks = networks
        self.labels = labels
    }
}
