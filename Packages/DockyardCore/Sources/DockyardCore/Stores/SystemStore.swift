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
