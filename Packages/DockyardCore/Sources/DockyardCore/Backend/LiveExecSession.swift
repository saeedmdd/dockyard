import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationOS
import Foundation

/// A real exec session: pipes on this side, a `ClientProcess` on the other.
final class LiveExecSession: ExecSessionHandle, @unchecked Sendable {
    private let process: ClientProcess
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe?
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var isClosed = false

    let output: AsyncStream<Data>

    init(process: ClientProcess, stdin: Pipe, stdout: Pipe, stderr: Pipe?) {
        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.output = stream
        self.continuation = continuation

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        // Only present without a terminal. With one, the runtime folds stderr
        // into stdout, which is what makes a shell prompt behave.
        stderr?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            continuation.yield(data)
        }
    }

    func send(_ data: Data) async {
        guard !data.isEmpty else { return }
        let shouldWrite = lock.withLock { !isClosed }
        guard shouldWrite else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func resize(columns: Int, rows: Int) async {
        guard columns > 0, rows > 0 else { return }
        try? await process.resize(
            Terminal.Size(width: UInt16(columns), height: UInt16(rows))
        )
    }

    func waitForExit() async -> Int32 {
        (try? await process.wait()) ?? -1
    }

    func close() async {
        let alreadyClosed = lock.withLock {
            let was = isClosed
            isClosed = true
            return was
        }
        guard !alreadyClosed else { return }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        // Closing stdin is how a shell is told the session is over; without it
        // the process would sit waiting for input that will never come.
        try? stdinPipe.fileHandleForWriting.close()
        try? await process.kill(SIGKILL)
        continuation.finish()
    }
}

/// Collects output from pipe callbacks, which arrive on arbitrary threads.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
