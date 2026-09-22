import Foundation

/// The log files the runtime keeps for one container.
public struct ContainerLogHandles: Sendable {
    /// The container process's merged stdout and stderr.
    public let stdio: FileHandle
    /// The guest VM's boot output, when the runtime provides it.
    public let boot: FileHandle?

    public init(stdio: FileHandle, boot: FileHandle?) {
        self.stdio = stdio
        self.boot = boot
    }

    public func handle(for source: LogSource) -> FileHandle? {
        switch source {
        case .stdio: stdio
        case .boot: boot
        }
    }
}
