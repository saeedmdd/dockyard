import Foundation

/// Every failure the UI can act on differently.
///
/// The important distinction is `daemonUnreachable` / `daemonTimeout` versus
/// everything else: those two mean "no point showing a per-row error, route the
/// whole window to onboarding", and they are what the app sees whenever
/// `container-apiserver` is not running.
public enum DockyardError: Error, Sendable, Equatable {
    /// `container-apiserver` is not running or not registered with launchd.
    case daemonUnreachable(String)
    /// The server accepted the connection but never answered.
    case daemonTimeout(String)
    /// The `container` CLI is not installed at the expected path.
    case cliMissing(path: String)
    /// A CLI invocation exited non-zero.
    case cliFailed(command: String, exitCode: Int32, output: String)
    /// Anything the runtime itself rejected (bad name, image in use, …).
    case upstream(code: String, message: String)
    /// A failure that carries no structure worth branching on.
    case other(String)

    /// True when the whole app should fall back to the daemon-down state rather
    /// than reporting this against a single row.
    public var isDaemonDown: Bool {
        switch self {
        case .daemonUnreachable, .daemonTimeout: true
        default: false
        }
    }
}

extension DockyardError {
    /// One line, for listing several failures together — a prune that removed
    /// most of what it swept and needs to say what it left behind.
    public var shortReason: String {
        errorDescription ?? "Unknown error"
    }
}

extension DockyardError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .daemonUnreachable:
            "The container system is not running."
        case .daemonTimeout:
            "The container system is not responding."
        case .cliMissing(let path):
            "The container CLI was not found at \(path)."
        case .cliFailed(let command, let exitCode, _):
            "`\(command)` failed with exit code \(exitCode)."
        case .upstream(_, let message):
            message
        case .other(let message):
            message
        }
    }

    public var failureReason: String? {
        switch self {
        case .daemonUnreachable(let detail), .daemonTimeout(let detail):
            detail
        case .cliFailed(_, _, let output):
            output.isEmpty ? nil : output
        case .upstream(let code, _):
            code
        default:
            nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .daemonUnreachable, .daemonTimeout:
            "Start it from the System panel, or run `container system start`."
        case .cliMissing:
            "Install Apple's container package, then restart Dockyard."
        default:
            nil
        }
    }
}
