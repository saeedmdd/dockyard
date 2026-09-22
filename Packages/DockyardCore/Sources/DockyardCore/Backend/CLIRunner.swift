import Foundation

/// One line of output from a `container` invocation.
public struct CLILine: Sendable, Hashable, Identifiable {
    public enum Stream: Sendable, Hashable {
        case stdout
        case stderr
    }

    public let id = UUID()
    public let stream: Stream
    public let text: String
    public let timestamp: Date

    public init(stream: Stream, text: String, timestamp: Date = Date()) {
        self.stream = stream
        self.text = text
        self.timestamp = timestamp
    }
}

/// The two daemon operations Dockyard shells out for.
///
/// A protocol so `SystemStore` can be tested against a scripted controller:
/// the streaming, failure and cancellation paths are the interesting ones and
/// none of them should require a real daemon to exercise.
public protocol DaemonController: Sendable {
    /// Whether Apple's `container` package is present.
    var isInstalled: Bool { get }
    /// Where the CLI was looked for, shown in the "not installed" screen.
    var executablePath: String { get }

    func systemStart() -> AsyncThrowingStream<CLILine, any Error>
    func systemStop() -> AsyncThrowingStream<CLILine, any Error>
}

/// Runs the `container` CLI.
///
/// Dockyard talks XPC for everything it can, but two jobs stay with the CLI
/// (see docs/PLAN.md decisions 7 and 8):
///
/// * `system start` / `system stop`, because starting the daemon means writing
///   a launchd plist with a symlink-resolved binary path and a filtered
///   environment — replicating that would mean owning Apple's installer logic.
/// * `build`, because upstream's build pipeline lives in the CLI, not in a
///   reusable client library.
///
/// Both are rare, user-initiated, long-running and text-streaming, which is
/// exactly what a process with a pipe is good at.
public struct CLIRunner: DaemonController {
    /// Where Apple's package installs the CLI.
    public static let defaultPath = "/usr/local/bin/container"

    /// Overrides the CLI location. Used to exercise the "not installed" state
    /// without touching `/usr/local/bin`, and by the path setting in T19.
    public static let pathOverrideEnvironmentKey = "DOCKYARD_CONTAINER_PATH"

    /// The override if one is set, otherwise the standard install location.
    public static var resolvedDefaultPath: String {
        ProcessInfo.processInfo.environment[pathOverrideEnvironmentKey] ?? defaultPath
    }

    public let executablePath: String

    public init(executablePath: String = CLIRunner.resolvedDefaultPath) {
        self.executablePath = executablePath
    }

    /// True when an executable file exists at `executablePath`.
    public var isInstalled: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: executablePath, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Streams a `container` invocation line by line, finishing when the process
    /// exits. A non-zero exit throws `DockyardError.cliFailed` carrying the
    /// output, so callers do not have to collect it themselves to report it.
    ///
    /// Cancelling the consuming task interrupts the process (SIGINT, then
    /// SIGTERM), which is how build cancellation works in T13.
    public func run(
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) -> AsyncThrowingStream<CLILine, any Error> {
        AsyncThrowingStream { continuation in
            guard isInstalled else {
                continuation.finish(throwing: DockyardError.cliMissing(path: executablePath))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            // Both streams matter: `system start` logs through the bootstrap
            // logger to stderr while `system stop` logs to stdout.
            let collected = OutputCollector()
            let stdoutReader = LineReader(stream: .stdout) { line in
                collected.append(line)
                continuation.yield(line)
            }
            let stderrReader = LineReader(stream: .stderr) { line in
                collected.append(line)
                continuation.yield(line)
            }
            stdout.fileHandleForReading.readabilityHandler = { stdoutReader.consume(handle: $0) }
            stderr.fileHandleForReading.readabilityHandler = { stderrReader.consume(handle: $0) }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Whatever arrived between the last readability callback and
                // exit, plus any line with no trailing newline.
                stdoutReader.drain(handle: stdout.fileHandleForReading)
                stderrReader.drain(handle: stderr.fileHandleForReading)

                let status = process.terminationStatus
                if status == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(
                        throwing: DockyardError.cliFailed(
                            command: "container \(arguments.joined(separator: " "))",
                            exitCode: status,
                            output: collected.text
                        )
                    )
                }
            }

            continuation.onTermination = { termination in
                guard case .cancelled = termination, process.isRunning else { return }
                process.interrupt()
                // Give it a moment to unwind before insisting.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { process.terminate() }
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(
                    throwing: DockyardError.other("failed to launch \(executablePath): \(error.localizedDescription)")
                )
            }
        }
    }

    /// Runs to completion and returns the output, for callers that do not want
    /// to stream.
    @discardableResult
    public func runToCompletion(_ arguments: [String]) async throws -> [CLILine] {
        var lines: [CLILine] = []
        for try await line in run(arguments) {
            lines.append(line)
        }
        return lines
    }

    // MARK: - Daemon lifecycle

    /// `container system start`. Writes the launchd plist for
    /// `com.apple.container.apiserver`, registers it, and waits for a ping.
    public func systemStart() -> AsyncThrowingStream<CLILine, any Error> {
        run(["system", "start"])
    }

    /// `container system stop`.
    ///
    /// This also stops every running container first (upstream gives them
    /// `SystemStop.stopTimeoutSeconds` to exit), so callers must confirm with
    /// the user before invoking it.
    public func systemStop() -> AsyncThrowingStream<CLILine, any Error> {
        run(["system", "stop"])
    }
}

// MARK: - Line assembly

/// Splits arriving bytes into lines, holding back a trailing partial line until
/// more data or process exit completes it.
private final class LineReader: @unchecked Sendable {
    private let stream: CLILine.Stream
    private let emit: @Sendable (CLILine) -> Void
    private let lock = NSLock()
    private var buffer = Data()

    init(stream: CLILine.Stream, emit: @escaping @Sendable (CLILine) -> Void) {
        self.stream = stream
        self.emit = emit
    }

    func consume(handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        append(data)
    }

    /// Reads whatever is left after exit and flushes any unterminated line.
    func drain(handle: FileHandle) {
        if let remaining = try? handle.readToEnd(), !remaining.isEmpty {
            append(remaining)
        }
        let leftover: Data? = lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : buffer
        }
        if let leftover, let text = String(data: leftover, encoding: .utf8), !text.isEmpty {
            emit(CLILine(stream: stream, text: text))
        }
    }

    private func append(_ data: Data) {
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var results: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let text = String(data: lineData, encoding: .utf8) {
                    results.append(text)
                }
            }
            return results
        }
        for line in lines {
            emit(CLILine(stream: stream, text: line))
        }
    }
}

/// Accumulates output so a failure can report what the command printed.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: CLILine) {
        lock.withLock {
            // Bounded: a runaway build should not grow this without limit.
            if lines.count >= 500 { lines.removeFirst() }
            lines.append(line.text)
        }
    }

    var text: String {
        lock.withLock { lines.joined(separator: "\n") }
    }
}
