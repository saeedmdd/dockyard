import Foundation
import Testing

@testable import DockyardCore

@Suite struct ContainerStatsSampleTests {

    private func reading(
        at seconds: TimeInterval,
        cpu: UInt64? = nil,
        memory: UInt64? = 100,
        limit: UInt64? = 1000,
        rx: UInt64? = nil,
        tx: UInt64? = nil,
        read: UInt64? = nil,
        written: UInt64? = nil,
        processes: UInt64? = nil
    ) -> RawContainerStats {
        RawContainerStats(
            id: "web",
            timestamp: Date(timeIntervalSince1970: seconds),
            memoryUsedBytes: memory,
            memoryLimitBytes: limit,
            cpuUsageMicroseconds: cpu,
            networkReceivedBytes: rx,
            networkSentBytes: tx,
            blockReadBytes: read,
            blockWrittenBytes: written,
            processCount: processes
        )
    }

    /// Upstream's definition: 100% is one fully used core. A container that
    /// consumed one second of CPU over one second of wall clock is at 100%.
    @Test func oneCoreFullyUsedIsOneHundredPercent() throws {
        let sample = try #require(
            ContainerStatsSample.between(
                reading(at: 0, cpu: 0),
                reading(at: 1, cpu: 1_000_000)
            )
        )
        #expect(abs(sample.cpuPercent - 100) < 0.001)
    }

    @Test func twoCoresFullyUsedIsTwoHundredPercent() throws {
        let sample = try #require(
            ContainerStatsSample.between(
                reading(at: 0, cpu: 0),
                reading(at: 1, cpu: 2_000_000)
            )
        )
        #expect(abs(sample.cpuPercent - 200) < 0.001)
    }

    @Test func halfACoreOverTwoSecondsIsFiftyPercent() throws {
        let sample = try #require(
            ContainerStatsSample.between(
                reading(at: 10, cpu: 5_000_000),
                reading(at: 12, cpu: 6_000_000)
            )
        )
        #expect(abs(sample.cpuPercent - 50) < 0.001)
    }

    @Test func idleContainerReportsZero() throws {
        let sample = try #require(
            ContainerStatsSample.between(
                reading(at: 0, cpu: 1_000_000),
                reading(at: 1, cpu: 1_000_000)
            )
        )
        #expect(sample.cpuPercent == 0)
    }

    /// Counters reset when a container restarts; a negative delta must not
    /// become a wildly negative percentage.
    @Test func counterGoingBackwardsIsTreatedAsZero() throws {
        let sample = try #require(
            ContainerStatsSample.between(
                reading(at: 0, cpu: 9_000_000, rx: 5000),
                reading(at: 1, cpu: 10_000, rx: 10)
            )
        )
        #expect(sample.cpuPercent == 0)
        #expect(sample.networkReceivedPerSecond == 0)
    }

    @Test func missingCPUFiguresYieldZeroRatherThanNoSample() throws {
        let sample = try #require(ContainerStatsSample.between(reading(at: 0), reading(at: 1)))
        #expect(sample.cpuPercent == 0)
        #expect(sample.memoryUsedBytes == 100)
    }

    @Test func throughputIsPerSecond() throws {
        let sample = try #require(
            ContainerStatsSample.between(
                reading(at: 0, rx: 1000, tx: 500, read: 4096, written: 0),
                reading(at: 2, rx: 3000, tx: 1500, read: 8192, written: 2048)
            )
        )
        #expect(sample.networkReceivedPerSecond == 1000)
        #expect(sample.networkSentPerSecond == 500)
        #expect(sample.blockReadPerSecond == 2048)
        #expect(sample.blockWrittenPerSecond == 1024)
    }

    /// Two readings with the same timestamp would divide by zero.
    @Test func zeroIntervalProducesNoSample() {
        #expect(ContainerStatsSample.between(reading(at: 5), reading(at: 5)) == nil)
    }

    @Test func missingMemoryProducesNoSample() {
        #expect(ContainerStatsSample.between(reading(at: 0), reading(at: 1, memory: nil)) == nil)
    }

    @Test func memoryFractionIsClampedAndOptional() {
        let within = ContainerStatsSample(
            timestamp: Date(), cpuPercent: 0, memoryUsedBytes: 512, memoryLimitBytes: 1024,
            networkReceivedPerSecond: 0, networkSentPerSecond: 0,
            blockReadPerSecond: 0, blockWrittenPerSecond: 0, processCount: nil
        )
        #expect(within.memoryFraction == 0.5)

        let over = ContainerStatsSample(
            timestamp: Date(), cpuPercent: 0, memoryUsedBytes: 2048, memoryLimitBytes: 1024,
            networkReceivedPerSecond: 0, networkSentPerSecond: 0,
            blockReadPerSecond: 0, blockWrittenPerSecond: 0, processCount: nil
        )
        #expect(over.memoryFraction == 1)

        let unlimited = ContainerStatsSample(
            timestamp: Date(), cpuPercent: 0, memoryUsedBytes: 512, memoryLimitBytes: nil,
            networkReceivedPerSecond: 0, networkSentPerSecond: 0,
            blockReadPerSecond: 0, blockWrittenPerSecond: 0, processCount: nil
        )
        #expect(unlimited.memoryFraction == nil)
    }
}

@MainActor
@Suite struct StatsStoreTests {

    @Test func firstReadingProducesNoSampleAndKeepsWarmingUp() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        // The interval is long enough that only the first reading lands inside
        // the window below.
        let store = StatsStore(backend: backend, interval: .seconds(30))

        store.start(containerID: "web")
        try? await Task.sleep(for: .milliseconds(120))

        #expect(backend.calls.stats == 1)
        #expect(store.isWarmingUp, "a single reading cannot produce a rate")
        #expect(store.samples.isEmpty)
        store.stop()
    }

    @Test func consecutiveReadingsProduceSamples() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        let store = StatsStore(backend: backend, interval: .milliseconds(30))

        store.start(containerID: "web")
        try? await Task.sleep(for: .milliseconds(250))
        store.stop()

        #expect(!store.isWarmingUp)
        #expect(store.samples.count >= 2)
        #expect(store.latest != nil)
    }

    /// The window is bounded, exactly like the log buffer.
    @Test func historyIsBounded() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        let store = StatsStore(backend: backend, interval: .milliseconds(1))

        store.start(containerID: "web")
        try? await Task.sleep(for: .milliseconds(600))
        store.stop()

        #expect(store.samples.count <= StatsStore.maximumSamples)
    }

    @Test func stoppingEndsSampling() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        let store = StatsStore(backend: backend, interval: .milliseconds(20))

        store.start(containerID: "web")
        try? await Task.sleep(for: .milliseconds(120))
        store.stop()
        let afterStop = backend.calls.stats
        let samplesAfterStop = store.samples.count
        try? await Task.sleep(for: .milliseconds(150))

        #expect(!store.isRunning)
        // What the store can promise is that it starts no new readings. One
        // already in flight when `stop()` lands still reaches the backend —
        // the call runs off the main actor — and asserting it could not was a
        // flake that failed roughly one run in ten.
        #expect(backend.calls.stats <= afterStop + 1, "no new readings started after stop")
        // What it must promise, and now does, is that such a reading is
        // discarded rather than charted.
        #expect(store.samples.count == samplesAfterStop, "nothing charted after stop")
    }

    /// Switching containers must not chart one container's history under
    /// another's name.
    @Test func switchingContainersDiscardsHistory() async {
        let backend = MockBackend(containers: [.stub(id: "web"), .stub(id: "db")])
        let store = StatsStore(backend: backend, interval: .milliseconds(30))

        store.start(containerID: "web")
        try? await Task.sleep(for: .milliseconds(150))
        store.start(containerID: "db")

        #expect(store.samples.isEmpty)
        #expect(store.isWarmingUp)
        store.stop()
    }

    @Test func daemonDownIsNotReportedAsAnError() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        backend.setFailure(.daemonUnreachable("down"))
        let store = StatsStore(backend: backend, interval: .milliseconds(20))

        store.start(containerID: "web")
        try? await Task.sleep(for: .milliseconds(80))
        store.stop()

        #expect(store.lastError == nil)
        #expect(store.samples.isEmpty)
    }
}
