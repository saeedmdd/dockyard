import Foundation

/// What `restart:` asked for. Nothing enforces this yet — T26's supervisor
/// does, and only while Dockyard is open.
public enum ComposeRestartPolicy: Sendable, Equatable, Codable {
    case no
    case always
    case onFailure(maxRetries: Int?)
    case unlessStopped

    /// Round-trips through a container label, so the supervisor can rebuild its
    /// table from the containers themselves rather than re-reading a file that
    /// may since have moved.
    public var labelValue: String {
        switch self {
        case .no: "no"
        case .always: "always"
        case .unlessStopped: "unless-stopped"
        case .onFailure(let max): max.map { "on-failure:\($0)" } ?? "on-failure"
        }
    }

    public init?(labelValue: String) {
        switch labelValue {
        case "no", "": self = .no
        case "always": self = .always
        case "unless-stopped": self = .unlessStopped
        case let value where value.hasPrefix("on-failure"):
            let parts = value.split(separator: ":", maxSplits: 1)
            self = .onFailure(maxRetries: parts.count == 2 ? Int(parts[1]) : nil)
        default: return nil
        }
    }

    public var restartsAutomatically: Bool { self != .no }
}

/// One `volumes:` entry in short syntax.
public struct ComposeMount: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// A path on this Mac.
        case bind
        /// A runtime-managed volume, named in the file.
        case named
        /// A destination with no source — the runtime provides storage.
        case anonymous
    }

    public let kind: Kind
    /// Host path for `.bind`, volume name for `.named`, empty for `.anonymous`.
    public let source: String
    public let destination: String
    public let readOnly: Bool

    public init(kind: Kind, source: String, destination: String, readOnly: Bool) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
    }
}

/// One `ports:` entry in short syntax.
public struct ComposePortMapping: Sendable, Equatable, Hashable, Codable {
    public let hostAddress: String?
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let networkProtocol: String

    public init(hostAddress: String?, hostPort: UInt16, containerPort: UInt16, networkProtocol: String) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.networkProtocol = networkProtocol
    }

    /// The `-p` argument shape `RunSpec.publishedPorts` expects.
    public var published: String {
        let mapping = "\(hostPort):\(containerPort)"
        let withHost = hostAddress.map { "\($0):\(mapping)" } ?? mapping
        return networkProtocol == "tcp" ? withHost : "\(withHost)/\(networkProtocol)"
    }
}

/// One service, after interpolation and with `env_file` already merged in.
public struct ComposeService: Sendable, Equatable {
    public var name: String
    public var image: String
    public var command: String
    public var entrypoint: String
    public var environment: [RunSpec.KeyValue]
    /// Paths as written in the file, relative to the compose file's directory.
    /// Read by `ComposeLoader`, never passed to the runtime — see T22 notes.
    public var envFiles: [String]
    public var ports: [ComposePortMapping]
    public var volumes: [ComposeMount]
    public var dependsOn: [String]
    public var restart: ComposeRestartPolicy
    public var workingDirectory: String
    public var user: String
    public var platform: String
    public var labels: [RunSpec.KeyValue]
    public var useInit: Bool
    public var readOnlyRootFilesystem: Bool
    public var allocateTerminal: Bool
    public var keepStdinOpen: Bool
    public var tmpfs: [String]
    public var addedCapabilities: [String]
    public var droppedCapabilities: [String]
    public var memory: String
    public var cpus: String
    public var shmSize: String
    /// `x-dockyard.rewrite: false` opts a service out of hostname rewriting.
    public var rewriteHostnames: Bool

    public init(name: String, image: String) {
        self.name = name
        self.image = image
        command = ""
        entrypoint = ""
        environment = []
        envFiles = []
        ports = []
        volumes = []
        dependsOn = []
        restart = .no
        workingDirectory = ""
        user = ""
        platform = ""
        labels = []
        useInit = false
        readOnlyRootFilesystem = false
        allocateTerminal = false
        keepStdinOpen = false
        tmpfs = []
        addedCapabilities = []
        droppedCapabilities = []
        memory = ""
        cpus = ""
        shmSize = ""
        rewriteHostnames = true
    }
}

/// A `volumes:` declaration at the top level of the file.
public struct ComposeVolumeDeclaration: Sendable, Equatable, Hashable {
    public let name: String
    /// Declared `external: true` — the runtime must already have it, and `down`
    /// must never remove it.
    public let isExternal: Bool

    public init(name: String, isExternal: Bool) {
        self.name = name
        self.isExternal = isExternal
    }
}

/// A whole compose file, parsed and resolved.
public struct ComposeProjectSpec: Sendable, Equatable {
    public var name: String
    public var fileURL: URL
    /// What relative paths in the file resolve against.
    public var directory: URL
    /// Sorted by name, so two loads of the same file are identical.
    public var services: [ComposeService]
    public var declaredVolumes: [ComposeVolumeDeclaration]

    public init(
        name: String,
        fileURL: URL,
        services: [ComposeService],
        declaredVolumes: [ComposeVolumeDeclaration] = []
    ) {
        self.name = name
        self.fileURL = fileURL
        self.directory = fileURL.deletingLastPathComponent()
        self.services = services.sorted { $0.name < $1.name }
        self.declaredVolumes = declaredVolumes
    }

    public func service(named name: String) -> ComposeService? {
        services.first { $0.name == name }
    }

    public var serviceNames: Set<String> { Set(services.map(\.name)) }
}
