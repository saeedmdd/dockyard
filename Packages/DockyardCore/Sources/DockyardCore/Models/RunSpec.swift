import Foundation

/// Everything the Run sheet can set, mirroring `container run`'s flags.
///
/// Deliberately a plain value type of strings and numbers, shaped like the
/// command line rather than like the runtime's configuration. The translation
/// into `Flags.*` happens in one place at the backend boundary, so this stays
/// free of upstream types and easy to test, and so the runtime performs exactly
/// the same validation it does for the CLI.
public struct RunSpec: Sendable, Equatable, Codable {
    // MARK: Basics
    public var image: String = ""
    /// Blank means the runtime mints one.
    public var name: String = ""
    /// Arguments after the image, replacing the image's default command.
    public var command: String = ""
    public var entrypoint: String = ""
    public var workingDirectory: String = ""
    public var user: String = ""
    public var allocateTerminal = false
    public var keepStdinOpen = false

    // MARK: Lifecycle
    /// Delete the container as soon as it exits.
    public var removeWhenStopped = false
    /// Start it immediately after creating it.
    public var startImmediately = true

    // MARK: Environment and storage
    public var environment: [KeyValue] = []
    public var environmentFiles: [String] = []
    /// `host:container[:ro]`.
    public var volumes: [String] = []
    /// `type=…,source=…,target=…` as `--mount` takes.
    public var mounts: [String] = []
    /// `/path:size`.
    public var tmpfs: [String] = []
    public var readOnlyRootFilesystem = false

    // MARK: Resources
    /// Blank means the runtime's default.
    public var cpus: String = ""
    /// e.g. "512m", "2g".
    public var memory: String = ""
    public var shmSize: String = ""

    // MARK: Networking
    /// `host:container[/proto]`.
    public var publishedPorts: [String] = []
    public var publishedSockets: [String] = []
    public var networks: [String] = []
    public var dnsNameservers: [String] = []
    public var dnsDomain: String = ""
    public var dnsSearchDomains: [String] = []
    public var dnsOptions: [String] = []
    public var disableDNS = false

    // MARK: Advanced
    /// Blank uses the host's architecture.
    public var platform: String = ""
    public var kernel: String = ""
    public var initImage: String = ""
    public var useInit = false
    public var labels: [KeyValue] = []
    public var addedCapabilities: [String] = []
    public var droppedCapabilities: [String] = []
    public var enableRosetta = false
    public var enableVirtualization = false
    public var forwardSSHAgent = false
    public var ulimits: [String] = []
    public var runtimeHandler: String = ""

    public init() {}

    public init(image: String) {
        self.image = image
    }

    /// A key/value pair the UI can edit as two fields.
    public struct KeyValue: Sendable, Equatable, Codable, Identifiable {
        public var id = UUID()
        public var key: String
        public var value: String

        public init(key: String = "", value: String = "") {
            self.key = key
            self.value = value
        }

        /// The `KEY=value` form the runtime expects.
        public var joined: String { "\(key)=\(value)" }

        public var isEmpty: Bool {
            key.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Command split the way a shell would, so `sh -c "echo hi"` keeps its
    /// quoted argument as one piece rather than three.
    public var commandArguments: [String] {
        Self.splitArguments(command)
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pairs with a key, in `KEY=value` form.
    public var environmentStrings: [String] {
        environment.filter { !$0.isEmpty }.map(\.joined)
    }

    public var labelStrings: [String] {
        labels.filter { !$0.isEmpty }.map(\.joined)
    }

    /// Problems worth stopping for before anything is sent to the runtime.
    ///
    /// This is a courtesy, not the authority: the runtime validates everything
    /// again, and `Utility.validEntityName` is what actually decides whether a
    /// name is acceptable.
    public var validationProblems: [String] {
        var problems: [String] = []
        if image.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Choose an image to run.")
        }
        if !trimmedName.isEmpty, !Self.isValidName(trimmedName) {
            problems.append(
                "“\(trimmedName)” isn’t a valid name. Use letters, digits, dots, hyphens and underscores, starting with a letter or digit."
            )
        }
        if !cpus.isEmpty, Int64(cpus) == nil {
            problems.append("CPUs must be a whole number.")
        }
        for port in publishedPorts where !Self.looksLikePortMapping(port) {
            problems.append("“\(port)” isn’t a port mapping. Use host:container, optionally with /tcp or /udp.")
        }
        return problems
    }

    public var isRunnable: Bool { validationProblems.isEmpty }

    /// Mirrors `ManagedContainer.nameValid`, which is the rule the runtime
    /// applies. Note it requires at least two characters.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    static func looksLikePortMapping(_ value: String) -> Bool {
        // host:container, with an optional /proto and an optional host address.
        value.range(of: #"^(\[?[0-9a-fA-F:.]+\]?:)?\d+:\d+(/(tcp|udp))?$"#, options: .regularExpression) != nil
    }

    /// Splits a command line on whitespace, honouring single and double quotes.
    static func splitArguments(_ input: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasContent = false

        for character in input {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasContent = true
            } else if character.isWhitespace {
                if hasContent || !current.isEmpty {
                    arguments.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(character)
            }
        }
        if hasContent || !current.isEmpty {
            arguments.append(current)
        }
        return arguments
    }
}
