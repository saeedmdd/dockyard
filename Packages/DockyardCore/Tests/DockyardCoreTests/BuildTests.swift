import Foundation
import Testing

@testable import DockyardCore

@Suite struct BuildSpecTests {

    private func spec(in directory: URL = URL(fileURLWithPath: "/tmp/ctx")) -> BuildSpec {
        var spec = BuildSpec(contextDirectory: directory)
        spec.tag = "myapp:dev"
        return spec
    }

    /// `--progress auto` emits a redrawing TTY display; piped into a text view
    /// that is a screenful of escape sequences.
    @Test func plainProgressIsAlwaysRequested() {
        let arguments = spec().commandArguments()
        #expect(arguments.contains("--progress"))
        #expect(arguments.contains("plain"))
    }

    @Test func tagAndContextAreIncluded() {
        let arguments = spec().commandArguments()
        #expect(arguments.first == "build")
        #expect(arguments.contains("--tag"))
        #expect(arguments.contains("myapp:dev"))
        #expect(arguments.last == "/tmp/ctx", "the context is the positional argument, and goes last")
    }

    /// The default filename is what the CLI uses anyway, so passing it would be
    /// noise in the command line the user can see.
    @Test func defaultDockerfileIsNotPassed() {
        #expect(!spec().commandArguments().contains("--file"))
    }

    @Test func alternateDockerfileIsPassed() {
        var spec = spec()
        spec.dockerfile = "Containerfile"
        let arguments = spec.commandArguments()
        #expect(arguments.contains("--file"))
        #expect(arguments.contains("Containerfile"))
    }

    @Test func optionalFlagsAppearOnlyWhenSet() {
        var spec = spec()
        #expect(!spec.commandArguments().contains("--no-cache"))
        #expect(!spec.commandArguments().contains("--target"))
        #expect(!spec.commandArguments().contains("--platform"))

        spec.noCache = true
        spec.target = "builder"
        spec.platform = "linux/arm64"

        let arguments = spec.commandArguments()
        #expect(arguments.contains("--no-cache"))
        #expect(arguments.contains("--target"))
        #expect(arguments.contains("builder"))
        #expect(arguments.contains("--platform"))
        #expect(arguments.contains("linux/arm64"))
    }

    @Test func buildArgumentsAndLabelsAreJoined() {
        var spec = spec()
        spec.buildArguments = [.init(key: "VERSION", value: "1.2"), .init(key: "", value: "skipped")]
        spec.labels = [.init(key: "team", value: "infra")]

        let arguments = spec.commandArguments()

        #expect(arguments.contains("VERSION=1.2"))
        #expect(!arguments.contains("=skipped"), "a pair with no key must not be sent")
        #expect(arguments.contains("team=infra"))
    }

    /// Build args carry things like URLs and flags, which routinely contain `=`.
    @Test func buildArgumentValuesKeepTheirEqualsSigns() {
        var spec = spec()
        spec.buildArguments = [.init(key: "OPTS", value: "a=1&b=2")]
        #expect(spec.commandArguments().contains("OPTS=a=1&b=2"))
    }

    // MARK: Validation

    @Test func aTagIsRequired() throws {
        let directory = try makeContext(withDockerfile: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var spec = BuildSpec(contextDirectory: directory)
        #expect(!spec.isBuildable)
        #expect(spec.validationProblems.contains { $0.contains("name") })

        spec.tag = "myapp:dev"
        #expect(spec.isBuildable)
    }

    @Test func missingDockerfileIsCaught() throws {
        let directory = try makeContext(withDockerfile: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        var spec = BuildSpec(contextDirectory: directory)
        spec.tag = "myapp:dev"

        #expect(!spec.isBuildable)
        #expect(spec.validationProblems.contains { $0.contains("Dockerfile") })
    }

    @Test func missingContextIsCaught() {
        var spec = BuildSpec(contextDirectory: URL(fileURLWithPath: "/nonexistent/folder"))
        spec.tag = "myapp:dev"
        #expect(spec.validationProblems.contains { $0.contains("folder") })
    }

    @Test func dockerfileIsDetectedInAFolder() throws {
        let directory = try makeContext(withDockerfile: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(BuildSpec.detectDockerfile(in: directory) == "Dockerfile")
    }

    @Test func containerfileIsDetectedToo() throws {
        let directory = try makeContext(withDockerfile: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "FROM alpine\n".write(
            to: directory.appendingPathComponent("Containerfile"), atomically: true, encoding: .utf8)

        #expect(BuildSpec.detectDockerfile(in: directory) == "Containerfile")
    }

    @Test func noDockerfileMeansNoDetection() throws {
        let directory = try makeContext(withDockerfile: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(BuildSpec.detectDockerfile(in: directory) == nil)
    }

    @Test(arguments: ["app", "app:dev", "ghcr.io/me/app:1.0", "localhost:5000/app:dev"])
    func validTagsAreAccepted(tag: String) {
        #expect(BuildSpec.isValidTag(tag), "\(tag) should be valid")
    }

    @Test(arguments: ["-app", "app tag", ""])
    func malformedTagsAreRejected(tag: String) {
        #expect(!BuildSpec.isValidTag(tag), "\(tag) should be rejected")
    }

    private func makeContext(withDockerfile: Bool) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dockyard-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if withDockerfile {
            try "FROM alpine:3.20\n".write(
                to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        }
        return directory
    }
}

/// A scripted build runner, so the store's behaviour can be tested without
/// spending a minute per case on a real build.
private final class ScriptedBuildRunner: BuildRunning, @unchecked Sendable {
    private let lines: [String]
    private let failure: DockyardError?
    private let delay: Duration

    init(lines: [String] = [], failure: DockyardError? = nil, delay: Duration = .zero) {
        self.lines = lines
        self.failure = failure
        self.delay = delay
    }

    func build(_ spec: BuildSpec) -> AsyncThrowingStream<CLILine, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [lines, failure, delay] in
                for text in lines {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(CLILine(stream: .stdout, text: text))
                }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }
}

@MainActor
@Suite struct BuildStoreTests {

    private func spec() -> BuildSpec {
        var spec = BuildSpec(contextDirectory: URL(fileURLWithPath: "/tmp/ctx"))
        spec.tag = "myapp:dev"
        return spec
    }

    @Test func successfulBuildKeepsItsOutputAndRefreshesImages() async {
        var refreshed = false
        let store = BuildStore(
            cli: ScriptedBuildRunner(lines: ["#1 [internal] load build definition", "#2 DONE"]),
            onSuccess: { refreshed = true }
        )

        let job = store.start(spec())
        await store.settle()

        #expect(job.state == .succeeded)
        #expect(job.output.lines.map(\.text) == ["#1 [internal] load build definition", "#2 DONE"])
        #expect(refreshed, "a finished build should refresh the images list")
    }

    /// A failed build's output is the whole diagnostic; replacing it with
    /// "exit code 1" would throw away the only useful information.
    @Test func failedBuildKeepsTheOutputThatExplainsIt() async {
        let store = BuildStore(
            cli: ScriptedBuildRunner(
                lines: ["#1 building"],
                failure: .cliFailed(
                    command: "container build",
                    exitCode: 1,
                    output: "#5 ERROR: process \"/bin/sh -c false\" did not complete successfully"
                )
            )
        )

        let job = store.start(spec())
        await store.settle()

        #expect(job.state == .failed(exitCode: 1))
        #expect(job.output.lines.contains { $0.text.contains("did not complete successfully") })
    }

    @Test func cancellingABuildIsNotReportedAsSuccess() async {
        let store = BuildStore(
            cli: ScriptedBuildRunner(lines: Array(repeating: "step", count: 200), delay: .milliseconds(5))
        )

        let job = store.start(spec())
        try? await Task.sleep(for: .milliseconds(40))
        job.cancel()
        await store.settle()

        #expect(job.state == .cancelled)
        #expect(job.state != .succeeded)
    }

    @Test func jobsCanBeDismissed() async {
        let store = BuildStore(cli: ScriptedBuildRunner(lines: ["done"]))
        let job = store.start(spec())
        await store.settle()

        store.dismiss(job)

        #expect(store.jobs.isEmpty)
    }

    @Test func twoBuildsAreTrackedSeparately() async {
        let store = BuildStore(cli: ScriptedBuildRunner(lines: ["done"]))

        let first = store.start(spec())
        var second = spec()
        second.tag = "other:dev"
        let secondJob = store.start(second)
        await store.settle()

        #expect(store.jobs.count == 2)
        #expect(first.spec.tag == "myapp:dev")
        #expect(secondJob.spec.tag == "other:dev")
    }

    /// Build output can run to thousands of lines; the buffer is bounded like
    /// the log view's.
    @Test func outputIsBounded() async {
        let store = BuildStore(cli: ScriptedBuildRunner(lines: (1...100).map { "line \($0)" }))
        let job = store.start(spec())
        await store.settle()

        #expect(job.output.count == 100)
        #expect(job.output.capacity == 20_000)
    }
}
