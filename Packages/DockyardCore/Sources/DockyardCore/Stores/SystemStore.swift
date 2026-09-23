import Foundation
import Observation

/// Owns the daemon's state and the two operations that change it.
///
/// Resolution order in `refresh()` matters: CLI presence is a local file check,
/// so it answers instantly and distinguishes "nothing installed" from "installed
/// but not running" — two states that need very different onboarding text.
@MainActor
@Observable
public final class SystemStore {
    public private(set) var status: DaemonStatus = .unknown
    /// Output of the most recent `system start` / `system stop`, shown live.
    public private(set) var transcript: [CLILine] = []
    /// Set when a start or stop fails, cleared when the next one begins.
    public private(set) var lastError: DockyardError?

    /// What the runtime is using on disk. Nil until first asked for: it is only
    /// wanted on the System panel, and the query walks the image store.
    public private(set) var diskUsage: DiskUsage?
    /// The kernel containers boot with. Asked for once — it does not change.
    public private(set) var kernel: KernelInfo?
    /// Which prune is running, so only its own button shows a spinner.
    public private(set) var pruning: PruneTarget?
    /// The outcome of the last prune, shown until the next one starts.
    public private(set) var lastPrune: PruneResult?
    /// Set when reading disk usage or pruning fails; separate from `lastError`
    /// so a failed prune is not wiped by the next status poll.
    public private(set) var panelError: DockyardError?

    private let backend: any ContainerBackend
    private let cli: any DaemonController
    private var operation: Task<Void, Never>?

    public init(backend: any ContainerBackend, cli: any DaemonController = CLIRunner()) {
        self.backend = backend
        self.cli = cli
    }

    /// Re-checks where the daemon stands.
    ///
    /// A no-op while a start or stop is running: that operation owns the status
    /// until it finishes, and a poll landing mid-start would otherwise flip the
    /// UI back to "stopped" for one tick.
    public func refresh() async {
        guard !status.isTransitioning else { return }
        status = await currentStatus()
    }

    private func currentStatus() async -> DaemonStatus {
        guard cli.isInstalled else {
            return .cliMissing(path: cli.executablePath)
        }
        do {
            let health = try await backend.health()
            if let server = health.semanticVersion, !health.matchesLinkedVersion {
                return .versionMismatch(
                    server: server,
                    client: DockyardCore.linkedContainerVersion,
                    health: health
                )
            }
            return .running(health)
        } catch let error as DockyardError where error.isDaemonDown {
            return .stopped
        } catch {
            // Reaching the server but failing for another reason still means the
            // app cannot work; treat it as stopped and show the detail.
            lastError = DockyardError(mapping: error)
            return .stopped
        }
    }

    // MARK: - Disk usage

    /// Re-reads disk usage, and the kernel if it has not been read yet.
    ///
    /// Silent while the daemon is down or changing state: the panel keeps the
    /// last numbers instead of blanking, and the status section already says
    /// why they are not moving.
    public func refreshUsage() async {
        guard status.isOperational else { return }
        do {
            diskUsage = try await backend.diskUsage()
            panelError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            return
        } catch {
            panelError = DockyardError(mapping: error)
        }
        if kernel == nil {
            // A missing kernel is not worth an error banner — the section just
            // does not appear.
            kernel = try? await backend.kernelInfo()
        }
    }

    /// Removes everything of one kind that nothing is using, then re-reads the
    /// numbers so the panel shows the result rather than what it swept.
    @discardableResult
    public func prune(_ target: PruneTarget) async -> PruneResult? {
        guard pruning == nil else { return nil }
        pruning = target
        lastPrune = nil
        panelError = nil
        defer { pruning = nil }
        do {
            let result = try await backend.prune(target)
            lastPrune = result
            await refreshUsage()
            return result
        } catch {
            panelError = DockyardError(mapping: error)
            return nil
        }
    }

    public func clearPanelError() {
        panelError = nil
    }

    public func clearLastPrune() {
        lastPrune = nil
    }

    // MARK: - System logs

    /// The most recent read of the runtime's own log, newest last.
    public private(set) var logLines: [CLILine] = []
    public private(set) var isLoadingLogs = false
    /// How many lines were dropped to keep the panel responsive.
    public private(set) var droppedLogLines = 0
    /// Bumped per read, so the view that renders the lines can compare one
    /// integer rather than the array.
    public private(set) var logVersion = 0
    public var logWindow: SystemLogWindow = .fiveMinutes

    /// A day of `log show` can run to six figures of lines, which a plain
    /// SwiftUI list cannot render. The tail is what anyone diagnosing a problem
    /// reads, so the head is dropped and the count is reported rather than
    /// silently truncating.
    public static let maximumLogLines = 2_000

    public func loadLogs() async {
        guard !isLoadingLogs else { return }
        isLoadingLogs = true
        logLines = []
        droppedLogLines = 0
        panelError = nil
        defer { isLoadingLogs = false }

        var collected: [CLILine] = []
        var dropped = 0
        do {
            for try await line in cli.systemLogs(last: logWindow) {
                collected.append(line)
                if collected.count > Self.maximumLogLines {
                    collected.removeFirst(collected.count - Self.maximumLogLines)
                    dropped += 1
                }
            }
        } catch is CancellationError {
            // Whatever arrived before the cancel is still worth showing.
        } catch {
            panelError = DockyardError(mapping: error)
        }
        logLines = collected
        droppedLogLines = dropped
        logVersion += 1
    }

    // MARK: - Lifecycle

    /// Runs `container system start`, streaming its output into `transcript`.
    public func start() {
        runLifecycle(transitionTo: .starting) { $0.systemStart() }
    }

    /// Runs `container system stop`.
    ///
    /// Callers must confirm first: upstream stops every running container
    /// before booting out the service.
    public func stop() {
        runLifecycle(transitionTo: .stopping) { $0.systemStop() }
    }

    /// Cancels an in-flight start or stop.
    public func cancelOperation() {
        operation?.cancel()
    }

    /// Waits for any in-flight start or stop to finish and for the status to be
    /// resolved. Returns immediately when nothing is running.
    public func settle() async {
        await operation?.value
    }

    /// `makeStream` is a closure, not a value: evaluating it at the call site
    /// would spawn the process before the guard below could reject a second
    /// click, leaving a stray `container system start` running.
    private func runLifecycle(
        transitionTo transitional: DaemonStatus,
        makeStream: (any DaemonController) -> AsyncThrowingStream<CLILine, any Error>
    ) {
        guard !status.isTransitioning else { return }
        let stream = makeStream(cli)
        operation?.cancel()
        transcript.removeAll()
        lastError = nil
        status = transitional

        operation = Task { [weak self] in
            do {
                for try await line in stream {
                    guard let self else { return }
                    self.transcript.append(line)
                }
            } catch is CancellationError {
                // Fall through: the status below reflects whatever actually
                // happened to the daemon, which is more useful than "cancelled".
            } catch {
                self?.lastError = DockyardError(mapping: error)
            }
            guard let self else { return }
            // Leave the transitional state before asking, or refresh() declines.
            self.status = .unknown
            await self.refresh()
            self.operation = nil
        }
    }
}
