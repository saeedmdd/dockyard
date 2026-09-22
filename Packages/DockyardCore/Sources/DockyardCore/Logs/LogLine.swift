import Foundation

/// Which log a line came from.
public enum LogSource: String, Sendable, Codable, CaseIterable, Identifiable {
    /// The container process's own output. stdout and stderr are merged into
    /// one file by the runtime, so they cannot be told apart here.
    case stdio
    /// The guest VM's boot output — where to look when a container dies before
    /// its process ever runs.
    case boot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stdio: "Output"
        case .boot: "Boot log"
        }
    }
}

/// One line of container output.
public struct LogLine: Sendable, Hashable, Identifiable {
    /// Monotonic within a tailing session; the position in the stream, which is
    /// stabler than the text for list identity.
    public let id: Int
    public let source: LogSource
    public let text: String

    public init(id: Int, source: LogSource, text: String) {
        self.id = id
        self.source = source
        self.text = text
    }
}

/// Something that happened to the log file itself, worth telling the user about
/// because it explains output vanishing.
public enum LogEvent: Sendable, Equatable {
    /// New lines arrived.
    case lines([LogLine])
    /// Lines were discarded because the container produced them faster than
    /// they could be shown. Reported rather than hidden, so a gap in the output
    /// is never silent.
    case dropped(Int)
    /// The file shrank — the container restarted and the runtime started a
    /// fresh log. Everything before this point is gone.
    case truncated
    /// The file went away.
    case ended
}

extension LogEvent {
    public static func == (lhs: LogEvent, rhs: LogEvent) -> Bool {
        switch (lhs, rhs) {
        case (.lines(let a), .lines(let b)): a == b
        case (.dropped(let a), .dropped(let b)): a == b
        case (.truncated, .truncated), (.ended, .ended): true
        default: false
        }
    }
}
