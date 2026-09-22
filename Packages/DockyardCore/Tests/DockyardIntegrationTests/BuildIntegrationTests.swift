import Foundation
import Testing

@testable import DockyardCore

/// Whether this machine can run builds at all.
///
/// The runtime's builder is a container of its own. If it cannot be
/// bootstrapped then no build can run — through Dockyard or through
/// `container build` directly — and a test that needs a completed build has
/// nothing to say about this code.
///
/// `builder status` is not the probe: it exits 0 and reports "builder is not
/// running" even when starting one is impossible. Starting it is the only thing
/// that answers the question, and on a healthy machine that is what the first
/// build would do anyway. Evaluated once, synchronously, so it can gate a suite.
enum BuilderProbe {
    static let isUsable: Bool = {
        guard IntegrationGate.isEnabled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLIRunner.defaultPath)
        process.arguments = ["builder", "start"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }()
}

/// Writes a build context and removes it afterwards.
func withBuildContext(
    dockerfile: String,
    _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dockyard-build-it-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try dockerfile.write(
        to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    try await body(directory)
}

/// Build behaviour that holds whatever state the builder is in.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct BuildIntegrationTests {

    /// A build that cannot succeed must surface as a non-zero exit carrying the
    /// output, never as a silent success.
    ///
    /// This runs everywhere: whether the build fails at its `RUN` step or
    /// because the builder will not start, the requirement is identical.
    @Test func failingBuildReportsTheErrorWithItsOutput() async throws {
        try await withFixture { fixture in
            try await withBuildContext(dockerfile: "FROM alpine:3.20\nRUN exit 7\n") { directory in
                var spec = BuildSpec(contextDirectory: directory)
                spec.tag = "\(fixture.prefix):failing"

                var thrown: (any Error)?
                do {
                    for try await _ in CLIRunner().build(spec) {}
                } catch {
                    thrown = error
                }

                let error = try #require(thrown as? DockyardError)
                guard case .cliFailed(let command, let exitCode, let output) = error else {
                    Issue.record("expected .cliFailed, got \(error)")
                    return
                }
                #expect(exitCode != 0)
                #expect(!output.isEmpty, "the failure output is the whole diagnostic")
                #expect(command.contains("--progress plain"))
            }
        }
    }

    /// Abandoning a build must kill it rather than let it finish in the
    /// background and quietly produce an image.
    @Test func cancellingLeavesNoImageBehind() async throws {
        try await withFixture { fixture in
            try await withBuildContext(dockerfile: "FROM alpine:3.20\nRUN sleep 90\n") { directory in
                var spec = BuildSpec(contextDirectory: directory)
                spec.tag = "\(fixture.prefix):cancelled"

                let task = Task {
                    for try await _ in CLIRunner().build(spec) {}
                }
                try await Task.sleep(for: .seconds(6))
                task.cancel()
                _ = try? await task.value
                try await Task.sleep(for: .seconds(3))

                let images = try await fixture.backend.listImages()
                #expect(!images.contains { $0.reference.contains("\(fixture.prefix):cancelled") })
            }
        }
    }
}

/// Builds that have to complete, so they only run where the builder works.
@Suite(.enabled(if: IntegrationGate.isEnabled && BuilderProbe.isUsable), .serialized)
struct CompletedBuildTests {

    @Test func buildProducesAnImage() async throws {
        try await withFixture { fixture in
            try await withBuildContext(dockerfile: "FROM alpine:3.20\nRUN echo hi > /hi\n") { directory in
                var spec = BuildSpec(contextDirectory: directory)
                spec.tag = "\(fixture.prefix):built"

                var lines: [String] = []
                for try await line in CLIRunner().build(spec) {
                    lines.append(line.text)
                }

                #expect(!lines.isEmpty, "a build should say what it is doing")
                let images = try await fixture.backend.listImages()
                #expect(images.contains { $0.reference.contains(fixture.prefix) })
            }
        }
    }

    /// `--progress plain` must be in effect: the default redrawing display
    /// would fill the output view with escape sequences.
    @Test func outputIsPlainTextNotATerminalDisplay() async throws {
        try await withFixture { fixture in
            try await withBuildContext(dockerfile: "FROM alpine:3.20\n") { directory in
                var spec = BuildSpec(contextDirectory: directory)
                spec.tag = "\(fixture.prefix):plain"

                var lines: [String] = []
                for try await line in CLIRunner().build(spec) {
                    lines.append(line.text)
                }

                #expect(!lines.joined().contains("\u{1B}["), "found ANSI escape sequences in the output")
            }
        }
    }
}
