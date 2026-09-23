import Foundation

/// The labels Dockyard writes on every container it creates from a compose file.
///
/// Labels are the only durable record that a container belongs to a project:
/// the compose file can move, change or be deleted, and a project still has to
/// be discoverable after the app restarts. Upstream uses the same technique for
/// its Kubernetes plugin, and reverse-DNS keys are its documented convention.
public enum ComposeLabels {
    /// Bumped if the meaning of any key below changes, so an old container is
    /// recognisable as one this version does not fully understand.
    public static let schemaVersion = "1"

    public static let schema = "io.dockyard.compose.version"
    public static let project = "io.dockyard.compose.project"
    public static let service = "io.dockyard.compose.service"
    /// Absolute path of the compose file this container came from.
    public static let file = "io.dockyard.compose.file"
    /// The directory relative paths in the file resolve against.
    public static let workdir = "io.dockyard.compose.workdir"
    /// Digest of the settings that produced this container, so `up` can tell
    /// "already correct" from "needs recreating" without guessing.
    public static let configHash = "io.dockyard.compose.config-hash"
    /// Comma-joined service names this one waits for.
    public static let dependsOn = "io.dockyard.compose.depends-on"
    /// The compose `restart:` policy, so the supervisor can rebuild its table
    /// from the containers themselves rather than re-reading a file that may
    /// have moved.
    public static let restart = "io.dockyard.compose.restart"

    /// A regex matching exactly one literal value, and nothing else.
    ///
    /// Upstream's container filter treats label values as **regular
    /// expressions**, so a project named `my.proj` would otherwise also match
    /// `myXproj` — and `down` deletes what the filter returns. Escaping is the
    /// difference between tearing down a project and tearing down somebody's
    /// unrelated work.
    public static func exactly(_ value: String) -> String {
        "^\(NSRegularExpression.escapedPattern(for: value))$"
    }

    /// The filter that selects exactly one project's containers.
    public static func filter(project: String) -> [String: String] {
        [Self.project: exactly(project)]
    }

    /// The labels a container of `service` in `project` carries.
    public static func labels(
        project: String,
        service: String,
        file: URL,
        configHash: String,
        dependsOn: [String],
        restart: String
    ) -> [String: String] {
        [
            schema: schemaVersion,
            Self.project: project,
            Self.service: service,
            Self.file: file.path,
            workdir: file.deletingLastPathComponent().path,
            Self.configHash: configHash,
            Self.dependsOn: dependsOn.sorted().joined(separator: ","),
            Self.restart: restart,
        ]
    }
}
