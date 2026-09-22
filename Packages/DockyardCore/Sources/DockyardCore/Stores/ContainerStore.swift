import Foundation
import Observation

/// The containers list.
@MainActor
@Observable
public final class ContainerStore {
    public private(set) var items: [ContainerItem] = []
    /// True only during the first load, so the UI can tell "still fetching"
    /// from "genuinely empty" without flashing a spinner on every poll.
    public private(set) var isLoadingInitially = true
    public private(set) var lastError: DockyardError?

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public var running: [ContainerItem] {
        items.filter { $0.status == .running }
    }

    public func item(id: String) -> ContainerItem? {
        items.first { $0.id == id }
    }

    public func refresh() async {
        do {
            items = try await backend.listContainers()
            lastError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            // Not reported here: the daemon-down state owns the whole window,
            // and a duplicate error on the list would be noise. Rows are
            // dropped so a restarted daemon never shows stale containers.
            items = []
            lastError = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
        isLoadingInitially = false
    }
}
