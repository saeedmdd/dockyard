import Foundation

/// A filesystem mounted into a container.
public struct MountInfo: Sendable, Hashable, Codable, Identifiable {
    /// How the runtime provides it. These are upstream's four public
    /// `Filesystem.FSType` cases — the `rootfs`/`data` distinction lives on an
    /// internal sub-enum and is not visible to clients.
    public enum Kind: String, Sendable, Codable {
        case block
        case volume
        /// A host folder shared into the container over virtiofs.
        case virtiofs
        case tmpfs

        public var title: String {
            switch self {
            case .block: "Block device"
            case .volume: "Volume"
            case .virtiofs: "Folder"
            case .tmpfs: "In-memory"
            }
        }

        public var symbol: String {
            switch self {
            case .block: "internaldrive"
            case .volume: "externaldrive"
            case .virtiofs: "folder"
            case .tmpfs: "memorychip"
            }
        }
    }

    public let kind: Kind
    /// Host path, volume name, or device, depending on `kind`.
    public let source: String
    public let destination: String
    public let isReadOnly: Bool
    /// Set when `kind` is `.volume`.
    public let volumeName: String?

    public var id: String { "\(source)→\(destination)" }

    /// True when the source is a host folder that must exist for the container
    /// to start.
    public var requiresHostPath: Bool { kind == .virtiofs }

    public init(
        kind: Kind,
        source: String,
        destination: String,
        isReadOnly: Bool,
        volumeName: String? = nil
    ) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.isReadOnly = isReadOnly
        self.volumeName = volumeName
    }
}

/// Everything the detail pane shows about one container.
///
/// Separate from `ContainerItem` because the list needs a handful of columns
/// for every row, while this is the full picture for exactly one.
public struct ContainerDetail: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let image: String
    public let status: ContainerStatus
    public let startedAt: Date?
    public let createdAt: Date

    // Process
    public let executable: String
    public let arguments: [String]
    /// `KEY=value` strings as the runtime stores them.
    public let environment: [String: String]
    public let workingDirectory: String
    public let user: String
    public let hasTerminal: Bool

    // Resources
    public let cpus: Int
    public let memoryInBytes: UInt64

    // Placement
    public let os: String
    public let architecture: String
    public let runtimeHandler: String
    public let isVirtualizationEnabled: Bool
    public let isRosettaEnabled: Bool
    public let isReadOnlyRootFilesystem: Bool

    // Connections
    public let ports: [PortMapping]
    public let networks: [NetworkAttachment]
    public let mounts: [MountInfo]
    public let dnsNameservers: [String]
    public let dnsDomain: String?
    public let dnsSearchDomains: [String]

    public let labels: [String: String]

    /// Mounts that are host folders, which are the ones that can go missing and
    /// stop the container from starting.
    public var hostFolderMounts: [MountInfo] {
        mounts.filter(\.requiresHostPath)
    }

    /// The container's own root filesystem arrives as a virtiofs mount at `/`;
    /// it is an implementation detail rather than something the user chose.
    public var userVisibleMounts: [MountInfo] {
        mounts.filter { $0.destination != "/" }
    }

    /// The command line as a user would type it.
    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }

    public init(
        id: String,
        image: String,
        status: ContainerStatus,
        startedAt: Date?,
        createdAt: Date,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        user: String,
        hasTerminal: Bool,
        cpus: Int,
        memoryInBytes: UInt64,
        os: String,
        architecture: String,
        runtimeHandler: String,
        isVirtualizationEnabled: Bool,
        isRosettaEnabled: Bool,
        isReadOnlyRootFilesystem: Bool,
        ports: [PortMapping],
        networks: [NetworkAttachment],
        mounts: [MountInfo],
        dnsNameservers: [String],
        dnsDomain: String?,
        dnsSearchDomains: [String],
        labels: [String: String]
    ) {
        self.id = id
        self.image = image
        self.status = status
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.hasTerminal = hasTerminal
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.os = os
        self.architecture = architecture
        self.runtimeHandler = runtimeHandler
        self.isVirtualizationEnabled = isVirtualizationEnabled
        self.isRosettaEnabled = isRosettaEnabled
        self.isReadOnlyRootFilesystem = isReadOnlyRootFilesystem
        self.ports = ports
        self.networks = networks
        self.mounts = mounts
        self.dnsNameservers = dnsNameservers
        self.dnsDomain = dnsDomain
        self.dnsSearchDomains = dnsSearchDomains
        self.labels = labels
    }
}
