import Foundation
import Testing

@testable import DockyardCore

/// The state machine that decides whether the user sees the app or onboarding.
@MainActor
@Suite struct SystemStoreTests {

    /// A path that exists and is executable, standing in for an installed CLI.
    private static let installedCLI = CLIRunner(executablePath: "/bin/echo")
    private static let missingCLI = CLIRunner(executablePath: "/nonexistent/container")

    @Test func startsOutUnknownBeforeAnyCheck() {
        let store = SystemStore(backend: MockBackend(), cli: Self.installedCLI)
        #expect(store.status == .unknown)
        #expect(!store.status.isOperational)
    }

    /// The local file check comes first: with nothing installed the app must say
    /// "install the package", not "the daemon is stopped".
    @Test func missingCLIIsReportedBeforeTheDaemonIsProbed() async {
        let backend = MockBackend()
        let store = SystemStore(backend: backend, cli: Self.missingCLI)

        await store.refresh()

        #expect(store.status == .cliMissing(path: "/nonexistent/container"))
        #expect(backend.calls.health == 0, "must not bother pinging when nothing is installed")
    }

    @Test func daemonDownBecomesStopped() async {
        let backend = MockBackend()
        backend.setFailure(.daemonUnreachable("XPC connection error: Connection invalid"))
        let store = SystemStore(backend: backend, cli: Self.installedCLI)

        await store.refresh()

        #expect(store.status == .stopped)
        #expect(!store.status.isOperational)
    }

    @Test func healthyDaemonBecomesRunning() async {
        let store = SystemStore(backend: MockBackend(), cli: Self.installedCLI)

        await store.refresh()

        #expect(store.status.isOperational)
        #expect(store.status.health?.semanticVersion == DockyardCore.linkedContainerVersion)
        if case .running = store.status {} else {
            Issue.record("expected .running, got \(store.status)")
        }
    }

    /// A mismatch is a banner, not a wall: the app stays usable.
    @Test func versionMismatchIsOperationalWithBothVersionsNamed() async {
        let backend = MockBackend(
            health: .stub(version: "container-apiserver version 2.5.0 (build: release, commit: abc1234)")
        )
        let store = SystemStore(backend: backend, cli: Self.installedCLI)

        await store.refresh()

        #expect(store.status.isOperational, "a mismatch must not block the user")
        #expect(
            store.status
                == .versionMismatch(
                    server: "2.5.0",
                    client: DockyardCore.linkedContainerVersion,
                    health: backend.stubbedHealth
                )
        )
    }

    /// Per T02: an unreadable version string is not grounds for a warning.
    @Test func unparseableServerVersionCountsAsRunning() async {
        let backend = MockBackend(health: .stub(version: "unspecified"))
        let store = SystemStore(backend: backend, cli: Self.installedCLI)

        await store.refresh()

        if case .running = store.status {} else {
            Issue.record("expected .running, got \(store.status)")
        }
    }

    /// A poll landing mid-start must not flip the UI back to "stopped".
    @Test func refreshIsIgnoredWhileTransitioning() async {
        let backend = MockBackend()
        backend.setFailure(.daemonUnreachable("down"))
        let store = SystemStore(backend: backend, cli: Self.installedCLI)
        store.start()

        #expect(store.status == .starting)
        await store.refresh()

        #expect(store.status.isTransitioning, "refresh must not interrupt an in-flight operation")
        store.cancelOperation()
    }

    // MARK: - start / stop

    /// The whole point of streaming: the user watches `system start` work.
    @Test func startStreamsOutputAndEndsInTheDaemonsRealState() async {
        let controller = ScriptedDaemonController(lines: [
            "Launching container-apiserver...",
            "Testing access to container-apiserver...",
            "Verifying machine API server is running...",
        ])
        let store = SystemStore(backend: MockBackend(), cli: controller)

        store.start()
        await store.settle()

        #expect(controller.startCount == 1)
        #expect(store.transcript.map(\.text).contains("Launching container-apiserver..."))
        #expect(store.transcript.count == 3)
        #expect(store.status.isOperational, "status must reflect the daemon, not the exit code")
        #expect(store.lastError == nil)
    }

    /// If the command fails, say so and show where it ended up.
    @Test func failedStartSurfacesTheErrorAndFallsBackToStopped() async {
        let backend = MockBackend()
        backend.setFailure(.daemonUnreachable("down"))
        let controller = ScriptedDaemonController(
            lines: ["Launching container-apiserver..."],
            failure: .cliFailed(command: "container system start", exitCode: 1, output: "boom")
        )
        let store = SystemStore(backend: backend, cli: controller)

        store.start()
        await store.settle()

        #expect(store.lastError == .cliFailed(command: "container system start", exitCode: 1, output: "boom"))
        #expect(store.status == .stopped)
    }

    @Test func stopUsesTheStopCommand() async {
        let backend = MockBackend()
        backend.setFailure(.daemonUnreachable("down"))
        let controller = ScriptedDaemonController(lines: ["stopping service"])
        let store = SystemStore(backend: backend, cli: controller)

        store.stop()
        await store.settle()

        #expect(controller.stopCount == 1)
        #expect(controller.startCount == 0)
        #expect(store.status == .stopped)
    }

    /// A second click while one is in flight must not spawn another process.
    @Test func startIsIgnoredWhileAlreadyStarting() async {
        let controller = ScriptedDaemonController(
            lines: ["one", "two", "three"],
            delayPerLine: .milliseconds(80)
        )
        let store = SystemStore(backend: MockBackend(), cli: controller)

        store.start()
        store.start()
        store.stop()
        await store.settle()

        #expect(controller.startCount == 1)
        #expect(controller.stopCount == 0)
    }

    @Test func cancellingAnOperationStopsTheStreamAndResolvesStatus() async {
        let controller = ScriptedDaemonController(
            lines: Array(repeating: "working", count: 50),
            delayPerLine: .milliseconds(40)
        )
        let store = SystemStore(backend: MockBackend(), cli: controller)

        store.start()
        try? await Task.sleep(for: .milliseconds(120))
        store.cancelOperation()
        await store.settle()

        #expect(controller.wasCancelled)
        #expect(!store.status.isTransitioning, "must not be stuck in .starting after cancelling")
        #expect(store.transcript.count < 50)
    }

    /// Each run starts with a clean transcript rather than appending forever.
    @Test func transcriptIsResetBetweenRuns() async {
        let controller = ScriptedDaemonController(lines: ["first run"])
        let store = SystemStore(backend: MockBackend(), cli: controller)

        store.start()
        await store.settle()
        store.start()
        await store.settle()

        #expect(store.transcript.map(\.text) == ["first run"])
    }

    @Test func statusSummariesAreDistinct() {
        let statuses: [DaemonStatus] = [
            .unknown, .cliMissing(path: "/x"), .stopped, .starting, .stopping,
            .versionMismatch(server: "2.0.0", client: "1.0.0", health: .stub()),
            .running(.stub()),
        ]
        #expect(Set(statuses.map(\.summary)).count == statuses.count)
    }

    @Test func onlyStartAndStopAreTransitional() {
        #expect(DaemonStatus.starting.isTransitioning)
        #expect(DaemonStatus.stopping.isTransitioning)
        #expect(!DaemonStatus.running(.stub()).isTransitioning)
        #expect(!DaemonStatus.stopped.isTransitioning)
        #expect(!DaemonStatus.unknown.isTransitioning)
    }
}
