import Foundation

/// Signals offered in the UI for killing a container.
///
/// The runtime takes a signal name as a string; this keeps the UI to the few
/// that make sense and out of the business of validating free text.
public enum ProcessSignal: String, Sendable, CaseIterable, Identifiable, Codable {
    /// Polite shutdown — what a graceful stop sends.
    case term = "SIGTERM"
    /// What ⌃C sends; many programs treat it as a request to quit.
    case interrupt = "SIGINT"
    /// Cannot be caught or ignored. The container dies immediately.
    case kill = "SIGKILL"
    /// Commonly used to make a server reload its configuration.
    case hangup = "SIGHUP"
    /// Often used to ask a process to dump state rather than exit.
    case quit = "SIGQUIT"

    public var id: String { rawValue }

    public var title: String { rawValue }

    public var detail: String {
        switch self {
        case .term: "Ask the container to shut down"
        case .interrupt: "Interrupt, as Control-C does"
        case .kill: "Force the container to stop immediately"
        case .hangup: "Hang up; many servers reload their configuration"
        case .quit: "Quit, often producing a core dump"
        }
    }

    /// True for signals that end the container abruptly, so the UI can warn.
    public var isAbrupt: Bool { self == .kill }
}
