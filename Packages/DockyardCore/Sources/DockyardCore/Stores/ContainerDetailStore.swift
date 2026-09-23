import Foundation
import Observation

/// Loads the detail pane's data for whichever container is selected.
///
/// Kept separate from `ContainerStore` because it follows the selection rather
/// than the list: it must reload when the user picks a different row, and stay
/// current while they sit on one.
@MainActor
@Observable
public final class ContainerDetailStore {
    public private(set) var detail: ContainerDetail?
    public private(set) var inspectJSON: String?
    public private(set) var lastError: DockyardError?
    public private(set) var isLoading = false

    /// The container currently being shown, if any.
    public private(set) var containerID: String?

    private let backend: any ContainerBackend
    /// Called whenever a detail is loaded, so the app can remember things the
    /// list does not carry — such as which volumes a container mounts.
    public var onDetailLoaded: ((ContainerDetail) -> Void)?

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    /// Points the pane at a container, clearing what was there if it changed.
    public func select(_ id: String?) async {
        guard id != containerID else { return }
        containerID = id
        detail = nil
        inspectJSON = nil
        lastError = nil
        await load()
    }

    /// Re-reads the selected container. Called on each poll so uptime and
    /// status stay live while the user reads the page.
    public func refresh() async {
        guard containerID != nil else { return }
        await load(showSpinner: false)
    }

    /// Fetches the inspect JSON, which is only needed when that tab is open.
    public func loadInspectJSON() async {
        guard let containerID, inspectJSON == nil else { return }
        do {
            inspectJSON = try await backend.containerInspectJSON(id: containerID)
        } catch let error as DockyardError where error.isDaemonDown {
            inspectJSON = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
    }

    private func load(showSpinner: Bool = true) async {
        guard let containerID else { return }
        if showSpinner { isLoading = true }
        do {
            let loaded = try await backend.containerDetail(id: containerID)
            detail = loaded
            onDetailLoaded?(loaded)
            lastError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            detail = nil
        } catch {
            // A container deleted from elsewhere is expected, not an error
            // worth shouting about; the pane simply empties.
            detail = nil
            lastError = DockyardError(mapping: error)
        }
        isLoading = false
    }
}
