import DockyardCore
import Observation
import SwiftUI

/// Root object for the app: owns the stores and the backend they talk to.
///
/// Created once in `DockyardApp` and injected into the environment, so the
/// window and the menu bar item show the same state.
@MainActor
@Observable
final class AppModel {
    let system: SystemStore

    /// Transient messages shown as toasts. T19 gives these a proper presenter;
    /// for now they carry failures that are not tied to a single row.
    private(set) var notice: DockyardError?

    private let backend: any ContainerBackend

    init(backend: any ContainerBackend = LiveBackend()) {
        self.backend = backend
        self.system = SystemStore(backend: backend)
    }

    /// First check after launch.
    func bootstrap() async {
        await system.refresh()
    }

    func show(_ error: DockyardError) {
        notice = error
    }

    func dismissNotice() {
        notice = nil
    }
}
