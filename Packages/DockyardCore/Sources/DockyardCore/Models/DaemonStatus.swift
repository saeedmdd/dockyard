import Foundation

/// Where the container system stands, as far as the app can tell.
///
/// This drives the whole window: anything other than `running` or
/// `versionMismatch` means the lists cannot load and the user sees onboarding
/// instead of empty tables.
public enum DaemonStatus: Sendable, Equatable {
    /// Not checked yet. Distinct from `stopped` so the app does not flash
    /// "not running" before the first health check answers.
    case unknown
    /// Apple's `container` package is not installed.
    case cliMissing(path: String)
    /// Installed, but `container-apiserver` is not running.
    case stopped
    /// A `system start` is in flight.
    case starting
    /// A `system stop` is in flight.
    case stopping
    /// Running, but not the version this build links. Usable, with a banner:
    /// the XPC protocol may differ.
    case versionMismatch(server: String, client: String, health: DaemonHealth)
    /// Running and matching.
    case running(DaemonHealth)

    /// True when the runtime can serve requests, so the app shows its lists.
    public var isOperational: Bool {
        switch self {
        case .running, .versionMismatch: true
        default: false
        }
    }

    /// True while a start or stop is in flight, so the UI can show progress and
    /// refuse to launch a second one.
    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }

    /// The server's details, when it answered.
    public var health: DaemonHealth? {
        switch self {
        case .running(let health), .versionMismatch(_, _, let health): health
        default: nil
        }
    }

    /// Short label for the menu bar and status pill.
    public var summary: String {
        switch self {
        case .unknown: "Checking…"
        case .cliMissing: "Not installed"
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .versionMismatch: "Version mismatch"
        case .running: "Running"
        }
    }
}
