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
    /// A failure from loading the list. Cleared by the next successful load.
    public private(set) var lastError: DockyardError?

    /// A failure from a start/stop/kill/delete.
    ///
    /// Kept apart from `lastError` because every action refreshes the list when
    /// it finishes, and a successful refresh would otherwise wipe the very
    /// error the user needs to see.
    public private(set) var actionError: DockyardError?

    /// Containers with an action in flight, and what was asked of them.
    ///
    /// Booting a VM takes a moment, so without this the row would sit unchanged
    /// until a poll caught up and the click would feel ignored.
    public private(set) var pending: [String: PendingAction] = [:]

    public enum PendingAction: String, Sendable, Equatable {
        case starting
        case stopping
        case killing
        case deleting

        /// What the row should read while the action is in flight.
        public var label: String {
            switch self {
            case .starting: "Starting…"
            case .stopping: "Stopping…"
            case .killing: "Killing…"
            case .deleting: "Deleting…"
            }
        }
    }

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

    public func pendingAction(for id: String) -> PendingAction? {
        pending[id]
    }

    /// Dismisses the action failure, once the user has seen it.
    public func clearActionError() {
        actionError = nil
    }

    /// Status to display, accounting for an action in flight.
    public func displayStatus(for container: ContainerItem) -> String {
        pending[container.id]?.label ?? container.status.rawValue.capitalized
    }

    // MARK: - Lifecycle actions

    @discardableResult
    public func start(_ id: String) async -> Bool {
        await perform(.starting, on: id) { try await $0.startContainer(id: id) }
    }

    @discardableResult
    public func stop(_ id: String) async -> Bool {
        await perform(.stopping, on: id) { try await $0.stopContainer(id: id) }
    }

    @discardableResult
    public func kill(_ id: String, signal: ProcessSignal = .kill) async -> Bool {
        await perform(.killing, on: id) { try await $0.killContainer(id: id, signal: signal) }
    }

    @discardableResult
    public func delete(_ id: String, force: Bool = false) async -> Bool {
        await perform(.deleting, on: id) { try await $0.deleteContainer(id: id, force: force) }
    }

    /// Deletes every stopped container, reporting how many actually went.
    @discardableResult
    public func pruneStopped() async -> (removed: Int, failed: Int) {
        let stopped = items.filter { $0.status == .stopped }
        var removed = 0
        var failed = 0
        for container in stopped {
            // One failure must not abandon the rest.
            if await perform(.deleting, on: container.id, refreshAfter: false, body: {
                try await $0.deleteContainer(id: container.id, force: false)
            }) {
                removed += 1
            } else {
                failed += 1
            }
        }
        await refresh()
        return (removed, failed)
    }

    /// Runs one action with its pending marker set, refreshing afterwards so
    /// the row shows the real state rather than an assumed one.
    @discardableResult
    private func perform(
        _ action: PendingAction,
        on id: String,
        refreshAfter: Bool = true,
        body: (any ContainerBackend) async throws -> Void
    ) async -> Bool {
        guard pending[id] == nil else { return false }
        pending[id] = action
        actionError = nil
        var succeeded = true
        do {
            try await body(backend)
        } catch {
            actionError = DockyardError(mapping: error)
            succeeded = false
        }
        // Cleared before refreshing, so the row never shows a stale "Starting…"
        // over data that already says "running".
        pending[id] = nil
        if refreshAfter { await refresh() }
        return succeeded
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
