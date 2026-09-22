import Foundation
import Observation

/// Drives periodic refreshes.
///
/// `apple/container` 1.0.0 exposes no event or watch API — the only streaming
/// endpoints are progress updates for pulls and builds — so staying current
/// means asking. XPC list calls are local and cheap, but they are not free, so
/// the loop runs only while something is on screen.
///
/// The tick closure is awaited before the next delay begins, so a slow refresh
/// spaces itself out instead of piling up.
@MainActor
@Observable
public final class Poller {
    /// True while the loop is running.
    public private(set) var isActive = false
    /// Number of completed ticks. Useful for tests and diagnostics.
    public private(set) var tickCount = 0

    public var interval: Duration {
        didSet {
            guard interval != oldValue, isActive else { return }
            // Restart so a shortened interval takes effect immediately rather
            // than after the current sleep.
            resume()
        }
    }

    private let tick: @MainActor () async -> Void
    private var task: Task<Void, Never>?

    public init(interval: Duration = .seconds(2), tick: @escaping @MainActor () async -> Void) {
        self.interval = interval
        self.tick = tick
    }

    // No `deinit` cancellation: `deinit` is nonisolated and cannot touch
    // main-actor state. The loop holds `self` weakly and returns on the first
    // tick after deallocation, so it cannot outlive the poller.

    /// Starts (or restarts) the loop, refreshing once immediately so a window
    /// that has just been reopened is never showing stale rows.
    public func resume() {
        task?.cancel()
        isActive = true
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                self.tickCount += 1
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // cancelled mid-sleep
                }
            }
        }
    }

    /// Stops the loop. Idle cost drops to zero, which is the point: a container
    /// GUI that burns CPU while hidden is a worse citizen than the CLI.
    public func pause() {
        task?.cancel()
        task = nil
        isActive = false
    }

    /// Refreshes once, right now, without disturbing the loop's schedule.
    public func tickNow() async {
        await tick()
        tickCount += 1
    }
}
