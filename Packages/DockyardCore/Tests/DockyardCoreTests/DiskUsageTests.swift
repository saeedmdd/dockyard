import Foundation
import Testing

@testable import DockyardCore

/// The numbers and wording on the System panel.
@Suite struct DiskUsageModelTests {

    @Test func totalsAddUpAcrossTheThreeKinds() {
        let usage = DiskUsage(
            images: ResourceUsage(total: 3, active: 1, sizeInBytes: 100, reclaimableBytes: 60),
            containers: ResourceUsage(total: 2, active: 2, sizeInBytes: 20, reclaimableBytes: 0),
            volumes: ResourceUsage(total: 1, active: 0, sizeInBytes: 5, reclaimableBytes: 5)
        )

        #expect(usage.totalBytes == 125)
        #expect(usage.totalReclaimableBytes == 65)
    }

    @Test func idleCountIsWhatIsNotInUse() {
        let usage = ResourceUsage(total: 9, active: 3, sizeInBytes: 1, reclaimableBytes: 0)
        #expect(usage.idleCount == 6)
    }

    /// The server reports both numbers independently, and nothing stops `active`
    /// from arriving larger than `total` for one tick mid-delete. A negative
    /// count on screen would look like a bug in the app.
    @Test func idleCountNeverGoesNegative() {
        let usage = ResourceUsage(total: 1, active: 4, sizeInBytes: 1, reclaimableBytes: 0)
        #expect(usage.idleCount == 0)
    }

    @Test func reclaimableFractionDrivesTheBar() {
        let half = ResourceUsage(total: 2, active: 1, sizeInBytes: 200, reclaimableBytes: 100)
        #expect(half.reclaimableFraction == 0.5)
    }

    /// Dividing by an empty store is the ordinary state of a fresh install.
    @Test func reclaimableFractionIsZeroWhenNothingIsStored() {
        let empty = ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0)
        #expect(empty.reclaimableFraction == 0)
    }

    /// Reclaimable is calculated separately from size and has been seen to come
    /// back larger; the bar must not overflow its track.
    @Test func reclaimableFractionIsClampedToOne() {
        let odd = ResourceUsage(total: 1, active: 0, sizeInBytes: 10, reclaimableBytes: 99)
        #expect(odd.reclaimableFraction == 1)
    }

    @Test func kernelInfoShowsTheFileAndPlatform() {
        let kernel = KernelInfo(
            path: "/Library/Application Support/com.apple.container/kernel/vmlinux",
            architecture: "arm64",
            os: "linux",
            arguments: ["console=hvc0"]
        )
        #expect(kernel.fileName == "vmlinux")
        #expect(kernel.platformDescription == "linux/arm64")
    }
}

@Suite struct PruneResultTests {

    @Test func summaryNamesWhatWasRemovedAndFreed() {
        let result = PruneResult(target: .images, removedCount: 3, reclaimedBytes: 1_500_000)
        #expect(result.summary.contains("Removed 3 images"))
        #expect(result.summary.contains("reclaimed"))
    }

    @Test func summaryIsSingularForOne() {
        let result = PruneResult(target: .containers, removedCount: 1, reclaimedBytes: 10)
        #expect(result.summary.contains("Removed 1 container"))
        #expect(!result.summary.contains("containers"))
    }

    /// Nothing to sweep is a success, and saying "Removed 0" reads like a
    /// failure.
    @Test func summaryForAnEmptySweepSaysThereWasNothingToDo() {
        let result = PruneResult(target: .volumes, removedCount: 0, reclaimedBytes: 0)
        #expect(result.summary == "Nothing to remove — no unused volumes")
    }

    /// Untagging images whose layers another image still shares frees nothing,
    /// which otherwise reads as a prune that silently did not work.
    @Test func summaryExplainsRemovingSomethingThatFreedNoSpace() {
        let result = PruneResult(target: .images, removedCount: 2, reclaimedBytes: 0)
        #expect(result.summary.contains("still in use"))
        #expect(!result.summary.contains("reclaimed 0"))
    }

    @Test func partialSweepsReportWhatWasLeftBehind() {
        let result = PruneResult(
            target: .containers,
            removedCount: 2,
            reclaimedBytes: 4,
            failures: ["web: in use", "db: in use"]
        )
        #expect(result.failedCount == 2)
        #expect(result.summary.contains("2 could not be removed"))
    }
}

/// Disk usage and pruning as the System panel drives them.
@MainActor
@Suite struct SystemPanelStoreTests {

    private static let installedCLI = CLIRunner(executablePath: "/bin/echo")

    private func runningStore(
        _ backend: MockBackend,
        cli: CLIRunner = SystemPanelStoreTests.installedCLI
    ) async -> SystemStore {
        let store = SystemStore(backend: backend, cli: cli)
        await store.refresh()
        return store
    }

    @Test func usageAndKernelArriveTogether() async {
        let backend = MockBackend()
        let store = await runningStore(backend)

        await store.refreshUsage()

        #expect(store.diskUsage == .stub())
        #expect(store.kernel?.fileName == "vmlinux")
    }

    /// The kernel cannot change while the daemon runs, so asking again on every
    /// visit to the panel would be an XPC round trip for a constant.
    @Test func theKernelIsOnlyAskedForOnce() async {
        let backend = MockBackend()
        let store = await runningStore(backend)

        await store.refreshUsage()
        await store.refreshUsage()
        await store.refreshUsage()

        #expect(backend.calls.kernelInfo == 1)
        #expect(backend.calls.diskUsage == 3)
    }

    /// Asking a stopped daemon for disk usage would throw on every poll and
    /// paint an error over a panel whose status section already says why.
    @Test func usageIsNotAskedForWhileTheDaemonIsDown() async {
        let backend = MockBackend(failure: .daemonUnreachable("Connection invalid"))
        let store = await runningStore(backend)
        #expect(store.status == .stopped)

        await store.refreshUsage()

        #expect(backend.calls.diskUsage == 0)
        #expect(store.panelError == nil)
    }

    /// A daemon that goes away between the poll and the query leaves the last
    /// numbers up rather than blanking the panel.
    @Test func aDaemonThatDiesMidQueryKeepsTheNumbersOnScreen() async {
        let backend = MockBackend()
        let store = await runningStore(backend)
        await store.refreshUsage()
        #expect(store.diskUsage != nil)

        backend.setFailure(.daemonUnreachable("Connection invalid"))
        await store.refreshUsage()

        #expect(store.diskUsage != nil)
        #expect(store.panelError == nil, "the status section reports this, not the usage section")
    }

    @Test func anOrdinaryFailureIsReportedOnThePanel() async {
        let backend = MockBackend()
        let store = await runningStore(backend)
        backend.setFailure(.upstream(code: "internalError", message: "disk usage unavailable"))

        await store.refreshUsage()

        #expect(store.panelError == .upstream(code: "internalError", message: "disk usage unavailable"))
    }

    @Test func pruningStoppedContainersLeavesTheRunningOnes() async {
        let backend = MockBackend(containers: [
            .stub(id: "web", status: .running),
            .stub(id: "old", status: .stopped),
            .stub(id: "older", status: .stopped),
        ])
        let store = await runningStore(backend)

        let result = await store.prune(.containers)

        #expect(result?.removedCount == 2)
        #expect(backend.currentContainers.map(\.id) == ["web"])
        #expect(store.lastPrune?.target == .containers)
    }

    @Test func pruningImagesKeepsTheOnesContainersUse() async {
        let backend = MockBackend(
            containers: [.stub(id: "web", image: "docker.io/library/nginx:1.27")],
            images: [
                .stub(reference: "docker.io/library/nginx:1.27"),
                .stub(reference: "docker.io/library/alpine:3.20"),
            ]
        )
        let store = await runningStore(backend)

        let result = await store.prune(.images)

        #expect(result?.removedCount == 1)
        #expect(backend.currentImages.map(\.reference) == ["docker.io/library/nginx:1.27"])
    }

    /// Reading it back is what the panel does, and a prune that reported four
    /// removals while the numbers stayed put would be worse than no numbers.
    @Test func theNumbersAreReReadAfterAPrune() async {
        let backend = MockBackend(containers: [.stub(id: "old", status: .stopped)])
        let store = await runningStore(backend)
        await store.refreshUsage()
        let before = backend.calls.diskUsage

        await store.prune(.containers)

        #expect(backend.calls.diskUsage == before + 1)
    }

    /// Two prunes at once would delete the same things twice and report the
    /// second sweep as having found nothing.
    @Test func asecondPruneIsRefusedWhileOneIsRunning() async {
        let backend = MockBackend(containers: [.stub(id: "old", status: .stopped)])
        let store = await runningStore(backend)

        async let first = store.prune(.containers)
        async let second = store.prune(.images)
        let results = await [first, second]

        #expect(results.compactMap { $0 }.count == 1)
        #expect(backend.calls.prune == 1)
    }

    @Test func aFailedPruneIsReportedAndNothingIsClaimed() async {
        let backend = MockBackend()
        let store = await runningStore(backend)
        backend.setFailure(.upstream(code: "internalError", message: "cannot delete"))

        let result = await store.prune(.images)

        #expect(result == nil)
        #expect(store.lastPrune == nil)
        #expect(store.panelError?.errorDescription == "cannot delete")
        #expect(store.pruning == nil, "the spinner must not be left running")
    }

    /// A prune that removed most of what it swept still has to say what it left.
    @Test func aPartialSweepSurvivesAsAResultRatherThanAnError() async {
        let backend = MockBackend(containers: [
            .stub(id: "old", status: .stopped),
            .stub(id: "stuck", status: .stopped),
        ])
        backend.setPrunePartialFailures(["stuck"])
        let store = await runningStore(backend)

        let result = await store.prune(.containers)

        #expect(result?.removedCount == 1)
        #expect(result?.failedCount == 1)
        #expect(store.panelError == nil)
        #expect(backend.currentContainers.map(\.id) == ["stuck"])
    }

    /// The outcome of a prune is stale the moment another one starts.
    @Test func startingAPruneClearsTheLastOutcome() async {
        let backend = MockBackend(containers: [.stub(id: "old", status: .stopped)])
        let store = await runningStore(backend)
        await store.prune(.containers)
        #expect(store.lastPrune != nil)

        backend.setFailure(.upstream(code: "internalError", message: "nope"))
        await store.prune(.images)

        #expect(store.lastPrune == nil)
    }
}

/// Reading the runtime's own log.
@MainActor
@Suite struct SystemLogTests {

    private static let installedCLI = CLIRunner(executablePath: "/bin/echo")

    private func runningStore(_ cli: ScriptedDaemonController) async -> SystemStore {
        let store = SystemStore(backend: MockBackend(), cli: cli)
        await store.refresh()
        return store
    }

    @Test func linesArriveInOrderAndTheWindowIsPassedThrough() async {
        let cli = ScriptedDaemonController(lines: ["first", "second", "third"])
        let store = await runningStore(cli)
        store.logWindow = .oneHour

        await store.loadLogs()

        #expect(store.logLines.map(\.text) == ["first", "second", "third"])
        #expect(cli.logWindows == [.oneHour])
        #expect(!store.isLoadingLogs)
    }

    /// `log show --last 1d` runs to six figures of lines; the tail is what
    /// anyone diagnosing a problem reads.
    @Test func onlyTheMostRecentLinesAreKept() async {
        let lines = (1...SystemStore.maximumLogLines + 500).map { "line \($0)" }
        let cli = ScriptedDaemonController(lines: lines)
        let store = await runningStore(cli)

        await store.loadLogs()

        #expect(store.logLines.count == SystemStore.maximumLogLines)
        #expect(store.logLines.first?.text == "line 501")
        #expect(store.logLines.last?.text == "line \(SystemStore.maximumLogLines + 500)")
        #expect(store.droppedLogLines == 500, "the panel says how many it dropped")
    }

    @Test func aFailureIsReportedOnThePanel() async {
        let cli = ScriptedDaemonController(
            lines: ["starting"],
            failure: .cliFailed(command: "system logs", exitCode: 1, output: "bad --last")
        )
        let store = await runningStore(cli)

        await store.loadLogs()

        #expect(store.panelError != nil)
        // Whatever arrived before the failure is still worth reading.
        #expect(store.logLines.map(\.text) == ["starting"])
    }

    /// A second Show while the first is still reading would interleave two
    /// `log show` runs into one list.
    @Test func asecondReadIsRefusedWhileOneIsRunning() async {
        let cli = ScriptedDaemonController(lines: ["a", "b"], delayPerLine: .milliseconds(30))
        let store = await runningStore(cli)

        async let first: Void = store.loadLogs()
        async let second: Void = store.loadLogs()
        _ = await [first, second]

        #expect(cli.logWindows.count == 1)
        #expect(store.logLines.map(\.text) == ["a", "b"])
    }
}
