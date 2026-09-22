import Foundation
import Observation

/// The images list.
@MainActor
@Observable
public final class ImageStore {
    public private(set) var items: [ImageItem] = []
    public private(set) var isLoadingInitially = true
    public private(set) var lastError: DockyardError?

    /// Whether the runtime's own builder and VM init images are listed.
    /// Hidden by default, matching `container image list`. T10 adds the toggle.
    public var showsInfrastructure = false

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    /// What the list should display, honouring `showsInfrastructure`.
    public var visibleItems: [ImageItem] {
        showsInfrastructure ? items : items.filter { !$0.isInfrastructure }
    }

    public var infrastructureCount: Int {
        items.count { $0.isInfrastructure }
    }

    public func refresh() async {
        do {
            items = try await backend.listImages()
            lastError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            items = []
            lastError = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
        isLoadingInitially = false
    }
}
