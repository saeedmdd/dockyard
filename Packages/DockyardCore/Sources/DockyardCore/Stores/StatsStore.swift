import Foundation
import Observation

/// Collects a container's resource usage while the Stats tab is open.
///
/// Runs at 1 Hz rather than on the main 2-second poll: rates want a short,
/// regular interval, and nobody watching a graph wants to wait two seconds for
/// it to move. It stops the moment the tab closes — T07 showed how expensive it
/// is to leave per-container work running behind a hidden view.
@MainActor
@Observable
public final class StatsStore {
    /// Two minutes of history at 1 Hz, which is as much as the charts show.
    public static let maximumSamples = 120

    public private(set) var samples: [ContainerStatsSample] = []
    public private(set) var lastError: DockyardError?
    public private(set) var isRunning = false
    /// True until the second reading arrives: the first one alone cannot
    /// produce a rate, and the UI should say so rather than draw a flat zero.
    public private(set) var isWarmingUp = true

    private let backend: any ContainerBackend
    private var containerID: String?
    private var previous: RawContainerStats?
    private var task: Task<Void, Never>?
    private let interval: Duration

    public init(backend: any ContainerBackend, interval: Duration = .seconds(1)) {
        self.backend = backend
        self.interval = interval
    }

    public var latest: ContainerStatsSample? { samples.last }

    /// Highest CPU seen in the window, so the chart's scale does not jump about.
    public var peakCPUPercent: Double {
        samples.map(\.cpuPercent).max() ?? 0
    }

    public var peakMemoryBytes: UInt64 {
        samples.map(\.memoryUsedBytes).max() ?? 0
    }

    /// Begins sampling a container, discarding any history from another one.
    public func start(containerID id: String) {
        guard id != containerID || !isRunning else { return }
        stop()
        containerID = id
        samples = []
        previous = nil
        isWarmingUp = true
        lastError = nil
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sampleOnce(id: id)
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func sampleOnce(id: String) async {
        do {
            let reading = try await backend.containerStats(id: id)
            defer { previous = reading }
            lastError = nil
            guard let previous else { return }
            guard let sample = ContainerStatsSample.between(previous, reading) else { return }
            isWarmingUp = false
            samples.append(sample)
            if samples.count > Self.maximumSamples {
                samples.removeFirst(samples.count - Self.maximumSamples)
            }
        } catch let error as DockyardError where error.isDaemonDown {
            lastError = nil
        } catch {
            // A container that stops while being watched throws; that is not
            // worth an alarming banner, so sampling simply pauses.
            lastError = DockyardError(mapping: error)
            previous = nil
        }
    }
}
