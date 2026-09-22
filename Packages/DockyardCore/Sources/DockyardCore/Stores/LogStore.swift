import Foundation
import Observation

/// Owns the log buffer for the container currently being viewed.
@MainActor
@Observable
public final class LogStore {
    public private(set) var buffer = LogBuffer()
    public private(set) var isFollowing = true
    public private(set) var lastError: DockyardError?
    public private(set) var isLoading = false
    /// True when the log was replaced under us, usually a container restart.
    public private(set) var wasTruncated = false

    /// Which log is being shown. Changing it restarts the tail.
    public var source: LogSource = .stdio {
        didSet {
            guard source != oldValue, let containerID else { return }
            Task { await start(containerID: containerID, force: true) }
        }
    }

    public var searchQuery = ""

    private let backend: any ContainerBackend
    private var containerID: String?
    private var tailer: LogTailer?
    private var consumer: Task<Void, Never>?

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public var matchIndices: [Int] {
        buffer.search(searchQuery)
    }

    /// Begins tailing a container's log, replacing whatever was being shown.
    public func start(containerID id: String, force: Bool = false) async {
        guard force || id != containerID else { return }
        stop()
        containerID = id
        buffer = LogBuffer()
        wasTruncated = false
        lastError = nil
        isLoading = true

        do {
            let handles = try await backend.logHandles(id: id)
            guard let handle = handles.handle(for: source) else {
                isLoading = false
                lastError = .upstream(
                    code: "notFound",
                    message: "This container has no \(source.title.lowercased())."
                )
                return
            }
            let tailer = LogTailer(handle: handle, source: source)
            self.tailer = tailer
            // Only the last `capacity` lines are read: a container logging in a
            // loop can put millions of lines on disk in seconds, and reading
            // more than the buffer can hold means loading megabytes purely to
            // throw them away.
            consume(tailer.stream(tailLines: buffer.capacity))
        } catch let error as DockyardError where error.isDaemonDown {
            lastError = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
        isLoading = false
    }

    /// Stops tailing and releases the file.
    public func stop() {
        consumer?.cancel()
        consumer = nil
        tailer?.stop()
        tailer = nil
        containerID = nil
    }

    public func setFollowing(_ following: Bool) {
        isFollowing = following
    }

    /// Clears the view without affecting the file on disk.
    public func clear() {
        buffer.removeAll()
        wasTruncated = false
    }

    private func consume(_ stream: AsyncStream<LogEvent>) {
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .lines(let lines):
                    self.buffer.append(lines.map(\.text), source: lines.first?.source ?? .stdio)
                case .dropped(let count):
                    self.buffer.recordDropped(count)
                case .truncated:
                    // The old lines describe a previous run of the container;
                    // keeping them alongside the new ones would be misleading.
                    self.buffer.removeAll()
                    self.wasTruncated = true
                case .ended:
                    return
                }
            }
        }
    }
}
