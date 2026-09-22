import Foundation

/// A process running inside a container, with its input and output wired to
/// something that can draw a terminal.
///
/// The runtime hands back a process handle; this owns the pipes on the app's
/// side. Upstream's `ProcessIO` is deliberately not used for the same reason as
/// in T05: it attaches to the *process's own* stdin and stdout, which is right
/// for a CLI and wrong for an app.
public protocol ExecSessionHandle: Sendable {
    /// Bytes the process has written. With a terminal allocated, stderr is
    /// folded into this too — that is what a TTY does.
    var output: AsyncStream<Data> { get }

    /// Sends keystrokes to the process.
    func send(_ data: Data) async

    /// Tells the process its window changed size, so full-screen programs
    /// redraw correctly.
    func resize(columns: Int, rows: Int) async

    /// Waits for the process to exit and returns its status.
    func waitForExit() async -> Int32

    /// Ends the session and releases the pipes.
    func close() async
}

/// What to run inside the container.
public struct ExecRequest: Sendable, Equatable {
    public var containerID: String
    /// Candidate shells, tried in order. Not every image has bash, and plenty
    /// of minimal ones have only `sh`.
    public var shellCandidates: [String]
    public var allocateTerminal: Bool
    public var columns: Int
    public var rows: Int

    public init(
        containerID: String,
        shellCandidates: [String] = ["/bin/bash", "/bin/sh"],
        allocateTerminal: Bool = true,
        columns: Int = 80,
        rows: Int = 24
    ) {
        self.containerID = containerID
        self.shellCandidates = shellCandidates
        self.allocateTerminal = allocateTerminal
        self.columns = columns
        self.rows = rows
    }
}
