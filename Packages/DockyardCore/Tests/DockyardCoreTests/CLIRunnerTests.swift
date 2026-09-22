import Foundation
import Testing

@testable import DockyardCore

/// Exercises the process plumbing against real binaries rather than the
/// `container` CLI, so these run anywhere: line splitting across chunk
/// boundaries, stderr capture, exit codes and cancellation.
@Suite struct CLIRunnerTests {

    private func shell(_ script: String) -> AsyncThrowingStream<CLILine, any Error> {
        CLIRunner(executablePath: "/bin/sh").run(["-c", script])
    }

    @Test func installedDetectsAnExecutableFile() {
        #expect(CLIRunner(executablePath: "/bin/sh").isInstalled)
        #expect(!CLIRunner(executablePath: "/nonexistent/container").isInstalled)
        #expect(!CLIRunner(executablePath: "/usr/bin").isInstalled, "a directory is not an executable")
    }

    @Test func missingExecutableFailsWithCLIMissing() async {
        let runner = CLIRunner(executablePath: "/nonexistent/container")
        await #expect(throws: DockyardError.cliMissing(path: "/nonexistent/container")) {
            for try await _ in runner.run(["system", "start"]) {}
        }
    }

    @Test func linesArriveSeparatelyAndInOrder() async throws {
        var lines: [String] = []
        for try await line in shell("echo one; echo two; echo three") {
            lines.append(line.text)
        }
        #expect(lines == ["one", "two", "three"])
    }

    /// `system start` logs to stderr and `system stop` to stdout, so both must
    /// be captured and distinguishable.
    @Test func stdoutAndStderrAreBothCapturedAndTagged() async throws {
        var byStream: [CLILine.Stream: [String]] = [:]
        for try await line in shell("echo to-stdout; echo to-stderr 1>&2") {
            byStream[line.stream, default: []].append(line.text)
        }
        #expect(byStream[.stdout] == ["to-stdout"])
        #expect(byStream[.stderr] == ["to-stderr"])
    }

    /// Upstream's progress output ends without a newline; dropping it would lose
    /// the last and often most interesting line.
    @Test func trailingLineWithoutNewlineIsStillEmitted() async throws {
        var lines: [String] = []
        for try await line in shell("printf 'no trailing newline'") {
            lines.append(line.text)
        }
        #expect(lines == ["no trailing newline"])
    }

    /// A line longer than one read chunk must not be split in two.
    @Test func longLineIsReassembledAcrossChunks() async throws {
        let length = 200_000
        var lines: [String] = []
        for try await line in shell("printf 'x%.0s' $(seq 1 \(length)); echo") {
            lines.append(line.text)
        }
        #expect(lines.count == 1)
        #expect(lines.first?.count == length)
    }

    @Test func nonZeroExitThrowsWithTheOutputAttached() async {
        do {
            for try await _ in shell("echo something failed 1>&2; exit 3") {}
            Issue.record("expected a failure")
        } catch let error as DockyardError {
            guard case .cliFailed(_, let exitCode, let output) = error else {
                Issue.record("expected .cliFailed, got \(error)")
                return
            }
            #expect(exitCode == 3)
            #expect(output.contains("something failed"))
        } catch {
            Issue.record("expected DockyardError, got \(error)")
        }
    }

    @Test func successfulRunFinishesWithoutThrowing() async throws {
        let lines = try await CLIRunner(executablePath: "/bin/sh").runToCompletion(["-c", "exit 0"])
        #expect(lines.isEmpty)
    }

    /// Build cancellation (T13) depends on this: abandoning the stream must kill
    /// the process rather than leave it running.
    @Test func cancellingTheConsumerTerminatesTheProcess() async throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dockyard-cancel-\(UUID().uuidString)")

        let task = Task {
            // Touches the marker only if allowed to run to completion.
            for try await _ in shell("echo started; sleep 30; touch '\(marker.path)'") {}
        }

        // Wait for the first line so the process is definitely up.
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(800))

        #expect(!FileManager.default.fileExists(atPath: marker.path), "process should have been killed")
    }
}
