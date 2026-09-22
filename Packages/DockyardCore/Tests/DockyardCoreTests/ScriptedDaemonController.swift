import Foundation

@testable import DockyardCore

/// A `DaemonController` whose output and outcome are scripted, so the streaming,
/// failure and cancellation paths can be tested without a daemon.
final class ScriptedDaemonController: DaemonController, @unchecked Sendable {
    let isInstalled: Bool
    let executablePath: String

    private let lock = NSLock()
    private var _lines: [String]
    private var _failure: DockyardError?
    private var _delayPerLine: Duration
    private var _startCount = 0
    private var _stopCount = 0
    /// Set when the consuming task cancels mid-stream.
    private var _wasCancelled = false

    init(
        isInstalled: Bool = true,
        executablePath: String = "/usr/local/bin/container",
        lines: [String] = [],
        failure: DockyardError? = nil,
        delayPerLine: Duration = .zero
    ) {
        self.isInstalled = isInstalled
        self.executablePath = executablePath
        _lines = lines
        _failure = failure
        _delayPerLine = delayPerLine
    }

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var wasCancelled: Bool { lock.withLock { _wasCancelled } }

    func systemStart() -> AsyncThrowingStream<CLILine, any Error> {
        lock.withLock { _startCount += 1 }
        return makeStream()
    }

    func systemStop() -> AsyncThrowingStream<CLILine, any Error> {
        lock.withLock { _stopCount += 1 }
        return makeStream()
    }

    private func makeStream() -> AsyncThrowingStream<CLILine, any Error> {
        let (lines, failure, delay) = lock.withLock { (_lines, _failure, _delayPerLine) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for text in lines {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    try Task.checkCancellation()
                    continuation.yield(CLILine(stream: .stderr, text: text))
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    self?.lock.withLock { self?._wasCancelled = true }
                }
                task.cancel()
            }
        }
    }
}
