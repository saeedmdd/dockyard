import Foundation
import Observation

/// Loads the image detail pane's data for whichever image is selected.
@MainActor
@Observable
public final class ImageDetailStore {
    public private(set) var detail: ImageDetail?
    public private(set) var inspectJSON: String?
    public private(set) var lastError: DockyardError?
    public private(set) var isLoading = false
    public private(set) var reference: String?

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public func select(_ reference: String?) async {
        guard reference != self.reference else { return }
        self.reference = reference
        detail = nil
        inspectJSON = nil
        lastError = nil
        await load()
    }

    /// Re-reads the current image, after a tag for instance.
    public func reload() async {
        inspectJSON = nil
        await load()
    }

    public func loadInspectJSON() async {
        guard let reference, inspectJSON == nil else { return }
        do {
            inspectJSON = try await backend.imageInspectJSON(reference: reference)
        } catch let error as DockyardError where error.isDaemonDown {
            inspectJSON = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
    }

    private func load() async {
        guard let reference else { return }
        isLoading = true
        do {
            // Resolving an image means fetching its index and then a manifest
            // and config per platform, so this is deliberately not part of the
            // list refresh.
            detail = try await backend.imageDetail(reference: reference)
            lastError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            detail = nil
        } catch {
            detail = nil
            lastError = DockyardError(mapping: error)
        }
        isLoading = false
    }
}
