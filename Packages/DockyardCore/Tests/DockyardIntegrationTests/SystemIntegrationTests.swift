import Foundation
import Testing

@testable import DockyardCore

/// The System panel's numbers, against the real runtime.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct SystemIntegrationTests {

    /// The app's numbers have to be the ones `container system df` reports, so
    /// the panel can never quietly drift from the CLI.
    ///
    /// The app is read on both sides of the CLI, and the CLI's numbers have to
    /// match one of those two readings. Comparing single readings does not
    /// work: the other suites run in parallel and create and delete containers
    /// throughout, so something usually moves in between. Bracketing keeps the
    /// check meaningful — a genuinely wrong number matches neither end.
    ///
    /// The app is on the outside rather than the CLI because an XPC call costs
    /// a round trip and `container system df` costs a process launch; putting
    /// the cheap side outside makes the window something changes in about half
    /// as wide. With the CLI outside this failed most runs.
    @Test func diskUsageMatchesTheCLI() async throws {
        try await ensureDaemonRunning()
        let backend = LiveBackend()

        for attempt in 1...8 {
            let before = try await backend.diskUsage()
            let cli = Self.parseCounts(try runCLI(["system", "df"]))
            let after = try await backend.diskUsage()

            // `TYPE TOTAL ACTIVE SIZE RECLAIMABLE`, one row per kind. Only the
            // counts are compared: the sizes are recomputed per call and differ
            // between two readings of an otherwise idle machine.
            let rows: [(String, ResourceUsage, ResourceUsage)] = [
                ("Images", before.images, after.images),
                ("Containers", before.containers, after.containers),
                ("Local Volumes", before.volumes, after.volumes),
            ]
            let mismatched = rows.filter { label, first, second in
                guard let reported = cli[label] else { return true }
                return reported != Counts(total: first.total, active: first.active)
                    && reported != Counts(total: second.total, active: second.active)
            }
            guard mismatched.isEmpty else {
                #expect(
                    attempt < 8,
                    """
                    \(mismatched.map(\.0).joined(separator: ", ")) never matched \
                    `container system df` across eight readings
                    """
                )
                continue
            }
            #expect(cli.keys.sorted() == ["Containers", "Images", "Local Volumes"])
            return
        }
    }

    @Test func theDefaultKernelIsARealFile() async throws {
        try await ensureDaemonRunning()
        let kernel = try await LiveBackend().kernelInfo()

        #expect(kernel.os == "linux")
        #expect(kernel.architecture == "arm64")
        #expect(
            FileManager.default.fileExists(atPath: kernel.path),
            "the runtime reported a kernel at \(kernel.path), which is not there"
        )
        #expect(!kernel.arguments.isEmpty)
    }

    /// Pruning volumes is the one sweep safe to run here: it takes only what
    /// nothing refers to, and the assertion below proves the fixture's own
    /// attached volume is not taken.
    ///
    /// Skipped rather than run when the machine already has volumes, since a
    /// prune would delete a developer's data to make a test pass.
    @Test(.enabled(if: SystemIntegrationTests.machineHasNoVolumes))
    func pruningVolumesTakesTheLooseOneAndKeepsTheAttachedOne() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let attached = fixture.name("kept")
            let loose = fixture.name("loose")
            var attachedSpec = VolumeSpec()
            attachedSpec.name = attached
            var looseSpec = VolumeSpec()
            looseSpec.name = loose
            _ = try await fixture.backend.createVolume(attachedSpec)
            _ = try await fixture.backend.createVolume(looseSpec)

            // A stopped container counts as a reference: its volume holds the
            // data it will see when it next starts.
            var spec = fixture.sleeperSpec("holder")
            spec.volumes = ["\(attached):/data"]
            try await fixture.create(spec)

            let result = try await fixture.backend.prune(.volumes)

            #expect(result.target == .volumes)
            #expect(result.removedCount == 1)
            #expect(result.failedCount == 0)
            let remaining = try await fixture.backend.listVolumes().map(\.name)
            #expect(remaining.contains(attached))
            #expect(!remaining.contains(loose))
        }
    }

    /// Pruning containers or images is destructive to whatever the developer
    /// keeps on this machine — every stopped container, every image nothing
    /// refers to — so it is not run by `DOCKYARD_INTEGRATION=1` alone. Both
    /// paths share their selection rule with the volume sweep above and are
    /// covered against the mock; this test is for a throwaway machine:
    /// `DOCKYARD_INTEGRATION=1 DOCKYARD_DESTRUCTIVE=1 swift test …`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCKYARD_DESTRUCTIVE"] == "1"))
    func pruningContainersTakesOnlyTheStoppedOnes() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let running = fixture.name("running")
            var spec = fixture.sleeperSpec("running")
            spec.name = running
            try await fixture.create(spec)
            try await fixture.backend.startContainer(id: running)
            try await fixture.create(fixture.sleeperSpec("stopped"))

            let result = try await fixture.backend.prune(.containers)

            #expect(result.removedCount >= 1)
            let remaining = try await fixture.backend.listContainers().map(\.id)
            #expect(remaining.contains(running))
            #expect(!remaining.contains(fixture.name("stopped")))
        }
    }

    /// A backend that was alive before the daemon restarted must still see the
    /// world afterwards.
    ///
    /// `ContainerClient` holds a reusable XPC connection. The CLI makes one per
    /// command and exits, so it never meets this; Dockyard outlives the daemon,
    /// and a client made before a `system stop` answered `list` with an empty
    /// array — not an error — once the daemon was back. The Containers screen
    /// went blank and stayed blank until the app was relaunched.
    ///
    /// Stopping the container system stops everything running in it, so this is
    /// held behind the same opt-in as the prunes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCKYARD_DESTRUCTIVE"] == "1"))
    func aBackendOutlivesARestartOfTheDaemon() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            try await fixture.create(fixture.sleeperSpec("survivor"))
            let before = try await fixture.backend.listContainers()
            #expect(before.contains { $0.id == fixture.name("survivor") })

            let runner = CLIRunner()
            for try await _ in runner.systemStop() {}
            for try await _ in runner.systemStart() {}
            _ = try await fixture.backend.health()

            let after = try await fixture.backend.listContainers()
            #expect(after.map(\.id).sorted() == before.map(\.id).sorted())
        }
    }

    /// Upstream's `image prune --all` deletes the builder and init images along
    /// with everything else unused, leaving the next build to re-pull them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCKYARD_DESTRUCTIVE"] == "1"))
    func pruningImagesKeepsTheRuntimesOwn() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            _ = try await fixture.backend.prune(.images)

            let remaining = try await fixture.backend.listImages()
            #expect(remaining.contains { $0.isInfrastructure })
        }
    }

    struct Counts: Equatable {
        var total: Int
        var active: Int
    }

    /// Reads TOTAL and ACTIVE per row of `container system df`. The label can be
    /// several words ("Local Volumes"), so the counts are located as the first
    /// two numeric columns rather than by a fixed offset.
    static func parseCounts(_ table: String) -> [String: Counts] {
        var result: [String: Counts] = [:]
        for line in table.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = columns.firstIndex(where: { Int($0) != nil }),
                first > 0,
                columns.count > first + 1,
                let total = Int(columns[first]),
                let active = Int(columns[first + 1])
            else { continue }
            result[columns[..<first].joined(separator: " ")] = Counts(total: total, active: active)
        }
        return result
    }

    /// Whether a volume prune here would only touch what this test made.
    ///
    /// Checked with the CLI because a trait condition cannot await. When the
    /// machine already has volumes the test is skipped, not failed and not
    /// quietly passed: deleting a developer's data to make a test green is not
    /// a trade worth making.
    static let machineHasNoVolumes: Bool = {
        guard IntegrationGate.isEnabled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLIRunner().executablePath)
        process.arguments = ["volume", "list", "--format", "json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let listed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        return listed?.isEmpty ?? false
    }()

    private func runCLI(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLIRunner().executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
