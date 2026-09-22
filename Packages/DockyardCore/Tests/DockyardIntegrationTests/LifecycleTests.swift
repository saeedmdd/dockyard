import Foundation
import Testing

@testable import DockyardCore

/// The whole container lifecycle against a real daemon.
///
/// These cover the paths where the app talks to the runtime for real —
/// bootstrapping a VM, publishing a port, tailing a log file — which is where
/// mocks have repeatedly been unable to catch the interesting failures.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct LifecycleTests {

    @Test func createStartStopDelete() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("lifecycle"))

            var container = try #require(try await fixture.backend.listContainers().first { $0.id == id })
            #expect(container.status == .stopped, "a created container should not be running yet")

            try await fixture.backend.startContainer(id: id)
            container = try #require(try await fixture.backend.listContainers().first { $0.id == id })
            #expect(container.status == .running)
            #expect(container.startedAt != nil)
            #expect(container.primaryIPv4 != nil, "a running container should have an address")

            try await fixture.backend.stopContainer(id: id)
            container = try #require(try await fixture.backend.listContainers().first { $0.id == id })
            #expect(container.status == .stopped)

            try await fixture.backend.deleteContainer(id: id, force: false)
            let remaining = try await fixture.backend.listContainers()
            #expect(!remaining.contains { $0.id == id })
        }
    }

    /// Starting twice must be a no-op rather than an error — a double click or
    /// a racing poll should not produce a failure.
    @Test func startingAnAlreadyRunningContainerIsHarmless() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("double-start"))

            try await fixture.backend.startContainer(id: id)
            try await fixture.backend.startContainer(id: id)

            let container = try #require(try await fixture.backend.listContainers().first { $0.id == id })
            #expect(container.status == .running)
        }
    }

    /// The runtime refuses to delete a running container without force, and the
    /// app must not quietly supply it.
    @Test func deletingARunningContainerNeedsForce() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("force-delete"))
            try await fixture.backend.startContainer(id: id)

            await #expect(throws: DockyardError.self) {
                try await fixture.backend.deleteContainer(id: id, force: false)
            }
            #expect(try await fixture.backend.listContainers().contains { $0.id == id })

            try await fixture.backend.deleteContainer(id: id, force: true)
            #expect(try await !fixture.backend.listContainers().contains { $0.id == id })
        }
    }

    @Test func killStopsARunningContainer() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("kill"))
            try await fixture.backend.startContainer(id: id)

            try await fixture.backend.killContainer(id: id, signal: .kill)

            // The runtime needs a moment to reap it.
            try await Task.sleep(for: .seconds(2))
            let container = try #require(try await fixture.backend.listContainers().first { $0.id == id })
            #expect(container.status != .running)
        }
    }

    /// The Run sheet's options have to survive the trip through `Flags` and
    /// `containerConfigFromFlags` and come back out of the runtime intact.
    @Test func runSpecOptionsReachTheRuntime() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            var spec = fixture.sleeperSpec("options")
            spec.environment = [
                .init(key: "GREETING", value: "hello"),
                // The value with an `=` in it has broken naïve parsing before.
                .init(key: "QUERY", value: "a=1&b=2"),
            ]
            spec.publishedPorts = ["18099:80"]
            spec.labels = [.init(key: "dockyard.test", value: "t12")]
            spec.cpus = "2"
            spec.memory = "512m"
            spec.workingDirectory = "/tmp"

            let id = try await fixture.create(spec)
            let detail = try await fixture.backend.containerDetail(id: id)

            #expect(detail.cpus == 2)
            #expect(detail.memoryInBytes == 512 * 1024 * 1024)
            #expect(detail.workingDirectory == "/tmp")
            #expect(detail.environment["GREETING"] == "hello")
            #expect(detail.environment["QUERY"] == "a=1&b=2")
            #expect(detail.labels["dockyard.test"] == "t12")
            #expect(detail.ports.contains { $0.hostPort == 18099 && $0.containerPort == 80 })
        }
    }

    /// A name the runtime rejects must fail before anything is created.
    @Test func invalidNameIsRejected() async throws {
        try await withFixture { fixture in
            var spec = RunSpec(image: IntegrationFixture.testImage)
            spec.name = fixture.name("bad name with spaces")
            spec.command = "sleep 5"

            await #expect(throws: (any Error).self) {
                _ = try await fixture.create(spec)
            }
        }
    }
}

/// Logs come from real files the runtime appends to, which is the only place
/// the tailer's behaviour can actually be verified.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct LogIntegrationTests {

    @Test func containerOutputReachesTheLogTailer() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            var spec = fixture.sleeperSpec("logs")
            spec.command = #"sh -c "echo dockyard-marker-one; echo dockyard-marker-two; sleep 60""#

            let id = try await fixture.create(spec)
            try await fixture.backend.startContainer(id: id)

            let handles = try await fixture.backend.logHandles(id: id)
            let tailer = LogTailer(handle: handles.stdio, source: .stdio)

            var lines: [String] = []
            let deadline = Task {
                try? await Task.sleep(for: .seconds(15))
                tailer.stop()
            }
            for await event in tailer.stream() {
                if case .lines(let batch) = event {
                    lines.append(contentsOf: batch.map(\.text))
                    if lines.count >= 2 { break }
                }
            }
            deadline.cancel()
            tailer.stop()

            #expect(lines.contains("dockyard-marker-one"))
            #expect(lines.contains("dockyard-marker-two"))
        }
    }

    /// Every container gets a boot log, which is where to look when one dies
    /// before its process runs.
    @Test func bootLogIsAvailable() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("bootlog"))
            try await fixture.backend.startContainer(id: id)

            let handles = try await fixture.backend.logHandles(id: id)

            #expect(handles.boot != nil, "the runtime should provide a boot log")
        }
    }
}

/// Stats only exist while a container runs, and rates need two readings.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct StatsIntegrationTests {

    @Test func twoReadingsProduceASensibleSample() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("stats"))
            try await fixture.backend.startContainer(id: id)

            let first = try await fixture.backend.containerStats(id: id)
            try await Task.sleep(for: .seconds(1))
            let second = try await fixture.backend.containerStats(id: id)

            let sample = try #require(ContainerStatsSample.between(first, second))
            #expect(sample.cpuPercent >= 0)
            #expect(sample.memoryUsedBytes > 0)
            #expect(sample.networkReceivedPerSecond >= 0)
            #expect(sample.memoryLimitBytes ?? 0 > 0)
        }
    }
}
