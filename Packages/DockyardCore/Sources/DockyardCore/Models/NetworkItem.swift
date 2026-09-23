import Foundation

/// A network the runtime manages.
public struct NetworkItem: Sendable, Hashable, Codable, Identifiable {
    /// How containers on it reach the outside world.
    public enum Mode: String, Sendable, Codable, CaseIterable, Identifiable {
        /// Containers have private addresses and the host translates for them.
        case nat
        /// Containers can only talk to each other on the same subnet.
        case hostOnly

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .nat: "NAT"
            case .hostOnly: "Host only"
            }
        }

        public var detail: String {
            switch self {
            case .nat: "Containers reach the outside world through this Mac"
            case .hostOnly: "Containers can only reach each other"
            }
        }
    }

    public let name: String
    public let mode: Mode
    public let createdAt: Date
    /// Assigned once the network is up, which is where containers' addresses
    /// come from.
    public let subnet: String?
    public let gateway: String?
    /// The runtime's own `default` network, which it needs and will not remove.
    public let isBuiltin: Bool
    public let labels: [String: String]

    public var id: String { name }

    public init(
        name: String,
        mode: Mode,
        createdAt: Date,
        subnet: String?,
        gateway: String?,
        isBuiltin: Bool,
        labels: [String: String]
    ) {
        self.name = name
        self.mode = mode
        self.createdAt = createdAt
        self.subnet = subnet
        self.gateway = gateway
        self.isBuiltin = isBuiltin
        self.labels = labels
    }
}

/// What to create.
public struct NetworkSpec: Sendable, Equatable {
    public var name: String = ""
    public var mode: NetworkItem.Mode = .nat
    /// Optional; the runtime picks one when this is blank.
    public var subnet: String = ""
    public var labels: [RunSpec.KeyValue] = []

    public init() {}

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedSubnet: String {
        subnet.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if trimmedName.isEmpty {
            problems.append("Give the network a name.")
        } else if !VolumeSpec.isValidName(trimmedName) {
            problems.append(
                "“\(trimmedName)” isn’t a valid name. Use letters, digits, dots, hyphens and underscores, starting with a letter or digit."
            )
        }
        if !trimmedSubnet.isEmpty, !Self.isValidSubnet(trimmedSubnet) {
            problems.append("“\(trimmedSubnet)” isn’t a subnet. Use CIDR, like 192.168.70.0/24.")
        }
        return problems
    }

    public var isValid: Bool { validationProblems.isEmpty }

    /// Dotted quad with a prefix length, which is what the runtime accepts.
    public static func isValidSubnet(_ value: String) -> Bool {
        guard
            value.range(of: #"^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$"#, options: .regularExpression) != nil
        else { return false }
        let parts = value.split(separator: "/")
        guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
        return parts[0].split(separator: ".").allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
