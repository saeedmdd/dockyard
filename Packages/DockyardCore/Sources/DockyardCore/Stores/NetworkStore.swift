import Foundation
import Observation

/// The networks list.
@MainActor
@Observable
public final class NetworkStore {
    public private(set) var items: [NetworkItem] = []
    public private(set) var isLoadingInitially = true
    public private(set) var lastError: DockyardError?
    /// Kept apart from `lastError` for the same reason as elsewhere: every
    /// action refreshes, and a successful refresh would clear it.
    public private(set) var actionError: DockyardError?

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public func refresh() async {
        do {
            items = try await backend.listNetworks()
            lastError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            items = []
            lastError = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
        isLoadingInitially = false
    }

    /// Containers attached to a network.
    ///
    /// Deleting a network out from under a container leaves it unable to
    /// start, so the UI says so first.
    public func containersOn(_ network: NetworkItem, in containers: [ContainerItem]) -> [ContainerItem] {
        containers.filter { container in
            container.networks.contains { $0.network == network.name }
        }
    }

    @discardableResult
    public func create(_ spec: NetworkSpec) async -> NetworkItem? {
        actionError = nil
        do {
            let network = try await backend.createNetwork(spec)
            await refresh()
            return network
        } catch {
            actionError = DockyardError(mapping: error)
            return nil
        }
    }

    @discardableResult
    public func delete(_ name: String) async -> Bool {
        actionError = nil
        do {
            try await backend.deleteNetwork(name: name)
            await refresh()
            return true
        } catch {
            actionError = DockyardError(mapping: error)
            return false
        }
    }

    public func clearActionError() {
        actionError = nil
    }
}
