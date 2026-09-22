import Foundation

/// A bounded, append-only store of log lines.
///
/// A chatty container produces lines faster than anyone can read them, so the
/// buffer keeps the most recent `capacity` and drops the rest. Without a bound,
/// a container logging in a loop would grow the app's memory until it died.
public struct LogBuffer: Sendable {
    /// How many lines are kept, and therefore how large the rendered document
    /// gets.
    ///
    /// This started at 100,000 and was cut after measuring. Against a container
    /// logging in a loop (~400,000 lines/second), 100k lines meant a ~5 MB text
    /// document that had to have text deleted from its front and be scrolled on
    /// every update: ~120% CPU and 570 MB resident. At 10,000 the same load
    /// costs ~17% CPU and 126 MB. The log file itself is untouched and still
    /// has everything — `container logs` remains the way to read further back.
    public static let defaultCapacity = 10_000

    public private(set) var lines: [LogLine] = []
    public let capacity: Int
    /// How many lines have been dropped to stay within `capacity`, so the UI
    /// can say so rather than silently lying about the history.
    public private(set) var droppedCount = 0
    /// Total ever appended, which is also the next line's id.
    public private(set) var totalCount = 0

    public init(capacity: Int = LogBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
        lines.reserveCapacity(min(self.capacity, 4096))
    }

    public var isEmpty: Bool { lines.isEmpty }
    public var count: Int { lines.count }

    /// Appends text lines, assigning ids, and trims to capacity.
    /// Returns the lines as stored.
    @discardableResult
    public mutating func append(_ texts: [String], source: LogSource) -> [LogLine] {
        guard !texts.isEmpty else { return [] }
        // A batch larger than the whole buffer would be built only to be
        // trimmed away; skip straight to the part that survives.
        var texts = texts
        if texts.count > capacity {
            let excess = texts.count - capacity
            texts.removeFirst(excess)
            droppedCount += excess
            totalCount += excess
        }
        var appended: [LogLine] = []
        appended.reserveCapacity(texts.count)
        for text in texts {
            appended.append(LogLine(id: totalCount, source: source, text: text))
            totalCount += 1
        }
        lines.append(contentsOf: appended)
        trim()
        return appended
    }

    /// Records lines the tailer discarded before they ever reached the buffer.
    public mutating func recordDropped(_ count: Int) {
        guard count > 0 else { return }
        droppedCount += count
        totalCount += count
    }

    public mutating func removeAll() {
        lines.removeAll(keepingCapacity: true)
        droppedCount = 0
        // `totalCount` deliberately keeps counting: ids must stay unique across
        // a clear, or a SwiftUI list would see two different lines with one id.
    }

    /// Indices of lines containing `query`, case-insensitively.
    public func search(_ query: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        return lines.indices.filter {
            lines[$0].text.range(of: query, options: .caseInsensitive) != nil
        }
    }

    /// The whole buffer as text, for Copy All.
    public func joined() -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    private mutating func trim() {
        let excess = lines.count - capacity
        guard excess > 0 else { return }
        lines.removeFirst(excess)
        droppedCount += excess
    }
}
