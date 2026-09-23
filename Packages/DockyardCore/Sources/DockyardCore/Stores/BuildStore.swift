import Foundation
import Observation

/// One build, and everything it has printed.
@MainActor
@Observable
public final class BuildJob: Identifiable, Sendable {
    public enum State: Sendable, Equatable {
        case running
        case succeeded
        case failed(exitCode: Int32)
        case cancelled
    }

    public let id = UUID()
    public let spec: BuildSpec
    public private(set) var state: State = .running
    public private(set) var output = LogBuffer(capacity: 20_000)
    public let startedAt = Date()
    public private(set) var finishedAt: Date?

    private var task: Task<Void, Never>?

    init(spec: BuildSpec) {
        self.spec = spec
    }

    public var isFinished: Bool { state != .running }

    public var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// The last line, which is the most useful summary while a build runs.
    public var lastLine: String? {
        output.lines.last?.text
    }

    /// The exit code, when the build failed with one.
    public var exitCode: Int32? {
        if case .failed(let code) = state { return code }
        return nil
    }

    func attach(_ task: Task<Void, Never>) {
        self.task = task
    }

    func append(_ line: CLILine) {
        output.append([line.text], source: .stdio)
    }

    func finish(_ state: State) {
        self.state = state
        finishedAt = Date()
        task = nil
    }

    public func cancel() {
        task?.cancel()
    }

    func waitUntilFinished() async {
        await task?.value
    }
}

/// Runs builds and keeps their output.
@MainActor
@Observable
public final class BuildStore {
    public private(set) var jobs: [BuildJob] = []

    private var cli: any BuildRunning
    /// Called with the finished job, so the caller can refresh and say what was
    /// built: a build takes long enough that the user has usually navigated
    /// away by the time it lands, and "a build finished" is not worth saying.
    ///
    /// Settable rather than an init parameter because the owner is usually the
    /// object that wants to be called back, and it cannot capture itself until
    /// it is fully initialised.
    public var onSuccess: (BuildJob) async -> Void
    /// Called with a job that failed. A build's output lives in its own row,
    /// but the row is on the Images screen and a build outlasts the user's
    /// attention, so something has to say it did not work.
    public var onFailure: (BuildJob) -> Void = { _ in }

    public init(cli: any BuildRunning = CLIRunner(), onSuccess: @escaping (BuildJob) async -> Void = { _ in }) {
        self.cli = cli
        self.onSuccess = onSuccess
    }

    /// Points the store at a different `container` binary.
    ///
    /// Builds already running keep the stream they started with; only the next
    /// one uses the new path.
    public func useRunner(_ runner: any BuildRunning) {
        cli = runner
    }

    public var activeJobs: [BuildJob] {
        jobs.filter { !$0.isFinished }
    }

    @discardableResult
    public func start(_ spec: BuildSpec) -> BuildJob {
        let job = BuildJob(spec: spec)
        jobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in cli.build(spec) {
                    job.append(line)
                }
                // As everywhere else: a cancelled stream finishes rather than
                // throwing, so success is never inferred from the loop ending.
                try Task.checkCancellation()
                job.finish(.succeeded)
                await onSuccess(job)
            } catch is CancellationError {
                job.finish(.cancelled)
            } catch let error as DockyardError {
                if case .cliFailed(_, let exitCode, let output) = error {
                    // The failing lines are the whole point of a build failure,
                    // so they are kept rather than replaced by a summary.
                    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                        job.append(CLILine(stream: .stderr, text: String(line)))
                    }
                    job.finish(.failed(exitCode: exitCode))
                    onFailure(job)
                } else {
                    job.append(CLILine(stream: .stderr, text: error.errorDescription ?? "Build failed"))
                    job.finish(.failed(exitCode: -1))
                    onFailure(job)
                }
            } catch {
                job.append(CLILine(stream: .stderr, text: error.localizedDescription))
                job.finish(.failed(exitCode: -1))
                onFailure(job)
            }
        }
        job.attach(task)
        return job
    }

    public func dismiss(_ job: BuildJob) {
        jobs.removeAll { $0.id == job.id }
    }

    public func settle() async {
        for job in jobs where !job.isFinished {
            await job.waitUntilFinished()
        }
    }
}

/// The one thing `BuildStore` needs, so it can be tested without running
/// `container build`.
public protocol BuildRunning: Sendable {
    func build(_ spec: BuildSpec) -> AsyncThrowingStream<CLILine, any Error>
}

extension CLIRunner: BuildRunning {}
