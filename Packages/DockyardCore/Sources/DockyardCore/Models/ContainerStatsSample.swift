import Foundation

/// One reading of a container's counters, exactly as the runtime reports them.
///
/// Every field is optional because the runtime leaves them out when a container
/// is not running or a subsystem has nothing to say. The counters are
/// cumulative, so a single reading means little — rates come from comparing two.
public struct RawContainerStats: Sendable, Hashable, Codable {
    public let id: String
    /// When this reading was taken, used as the denominator for rates.
    public let timestamp: Date
    public let memoryUsedBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    /// Cumulative CPU time consumed, in microseconds.
    public let cpuUsageMicroseconds: UInt64?
    public let networkReceivedBytes: UInt64?
    public let networkSentBytes: UInt64?
    public let blockReadBytes: UInt64?
    public let blockWrittenBytes: UInt64?
    public let processCount: UInt64?

    public init(
        id: String,
        timestamp: Date = Date(),
        memoryUsedBytes: UInt64?,
        memoryLimitBytes: UInt64?,
        cpuUsageMicroseconds: UInt64?,
        networkReceivedBytes: UInt64?,
        networkSentBytes: UInt64?,
        blockReadBytes: UInt64?,
        blockWrittenBytes: UInt64?,
        processCount: UInt64?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.networkReceivedBytes = networkReceivedBytes
        self.networkSentBytes = networkSentBytes
        self.blockReadBytes = blockReadBytes
        self.blockWrittenBytes = blockWrittenBytes
        self.processCount = processCount
    }
}

/// A point on the charts: absolute values plus the rates derived from the
/// previous reading.
public struct ContainerStatsSample: Sendable, Hashable, Identifiable {
    public let id: Date
    public var timestamp: Date { id }

    /// Percentage of one core. 200% means two cores fully busy, which is how
    /// `container stats` reports it too.
    public let cpuPercent: Double
    public let memoryUsedBytes: UInt64
    public let memoryLimitBytes: UInt64?
    /// Bytes per second since the previous reading.
    public let networkReceivedPerSecond: Double
    public let networkSentPerSecond: Double
    public let blockReadPerSecond: Double
    public let blockWrittenPerSecond: Double
    public let processCount: UInt64?

    public var memoryFraction: Double? {
        guard let memoryLimitBytes, memoryLimitBytes > 0 else { return nil }
        return min(1, Double(memoryUsedBytes) / Double(memoryLimitBytes))
    }

    public init(
        timestamp: Date,
        cpuPercent: Double,
        memoryUsedBytes: UInt64,
        memoryLimitBytes: UInt64?,
        networkReceivedPerSecond: Double,
        networkSentPerSecond: Double,
        blockReadPerSecond: Double,
        blockWrittenPerSecond: Double,
        processCount: UInt64?
    ) {
        self.id = timestamp
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkReceivedPerSecond = networkReceivedPerSecond
        self.networkSentPerSecond = networkSentPerSecond
        self.blockReadPerSecond = blockReadPerSecond
        self.blockWrittenPerSecond = blockWrittenPerSecond
        self.processCount = processCount
    }
}

extension ContainerStatsSample {
    /// Derives a chartable sample from two consecutive readings.
    ///
    /// Returns `nil` when the readings cannot produce a meaningful rate: no
    /// time passed between them, or the runtime reported no memory figure.
    /// Counters that went backwards — which happens when a container restarts
    /// and its cgroup counters reset — are treated as zero rather than as an
    /// enormous negative rate.
    public static func between(_ previous: RawContainerStats, _ current: RawContainerStats) -> ContainerStatsSample? {
        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return nil }
        guard let memoryUsed = current.memoryUsedBytes else { return nil }

        return ContainerStatsSample(
            timestamp: current.timestamp,
            cpuPercent: cpuPercent(previous, current, interval: interval),
            memoryUsedBytes: memoryUsed,
            memoryLimitBytes: current.memoryLimitBytes,
            networkReceivedPerSecond: rate(previous.networkReceivedBytes, current.networkReceivedBytes, interval),
            networkSentPerSecond: rate(previous.networkSentBytes, current.networkSentBytes, interval),
            blockReadPerSecond: rate(previous.blockReadBytes, current.blockReadBytes, interval),
            blockWrittenPerSecond: rate(previous.blockWrittenBytes, current.blockWrittenBytes, interval),
            processCount: current.processCount
        )
    }

    /// Matches upstream: CPU time consumed over wall-clock time elapsed, where
    /// 100% is one fully used core.
    private static func cpuPercent(
        _ previous: RawContainerStats,
        _ current: RawContainerStats,
        interval: TimeInterval
    ) -> Double {
        guard let before = previous.cpuUsageMicroseconds, let after = current.cpuUsageMicroseconds,
            after > before
        else { return 0 }
        let usedSeconds = Double(after - before) / 1_000_000
        return (usedSeconds / interval) * 100
    }

    private static func rate(_ before: UInt64?, _ after: UInt64?, _ interval: TimeInterval) -> Double {
        guard let before, let after, after > before else { return 0 }
        return Double(after - before) / interval
    }
}
