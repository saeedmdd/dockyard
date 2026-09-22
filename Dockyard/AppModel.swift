import DockyardCore
import Observation
import SwiftUI

/// Which sidebar section is selected.
/// A request to open the Run sheet, optionally for a particular image.
struct RunSheetRequest: Identifiable {
    let id = UUID()
    var image: ImageItem?
}

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .system: "gearshape"
        }
    }

    /// Sections whose screens arrive in later tasks.
    var isImplemented: Bool {
        switch self {
        case .containers, .images: true
        case .volumes, .networks, .system: false
        }
    }
}

/// Root object for the app: owns the stores, the backend and the poll loop.
@MainActor
@Observable
final class AppModel {
    let system: SystemStore
    let containers: ContainerStore
    let containerDetail: ContainerDetailStore
    let logs: LogStore
    let stats: StatsStore
    let images: ImageStore
    let imageDetail: ImageDetailStore
    let run: RunStore

    var selectedSection: SidebarSection = .containers
    var selectedContainerID: ContainerItem.ID? {
        didSet {
            guard selectedContainerID != oldValue else { return }
            Task { await containerDetail.select(selectedContainerID) }
        }
    }
    var selectedImageID: ImageItem.ID? {
        didSet {
            guard selectedImageID != oldValue else { return }
            Task { await imageDetail.select(selectedImageID) }
        }
    }
    /// Set by the menu command so the Images screen can open its pull sheet.
    var isPullSheetRequested = false
    /// Set by the menu command or an image's Run button; carries the image to
    /// pre-fill when there is one.
    var runSheetRequest: RunSheetRequest?

    private(set) var notice: DockyardError?

    /// Polling runs only while the user can see something. Two independent
    /// surfaces can demand it, so they are tracked separately rather than as
    /// one flag that whichever closes last would clear.
    private var isWindowVisible = false { didSet { syncPolling() } }
    private var isMenuOpen = false { didSet { syncPolling() } }

    private let backend: any ContainerBackend
    private(set) var poller: Poller!

    init(backend: any ContainerBackend = LiveBackend()) {
        self.backend = backend
        self.system = SystemStore(backend: backend)
        self.containers = ContainerStore(backend: backend)
        self.containerDetail = ContainerDetailStore(backend: backend)
        self.logs = LogStore(backend: backend)
        self.stats = StatsStore(backend: backend)
        self.images = ImageStore(backend: backend)
        self.imageDetail = ImageDetailStore(backend: backend)
        self.run = RunStore(backend: backend)
        self.poller = Poller(interval: .seconds(2)) { [weak self] in
            await self?.tick()
        }
    }

    /// One poll: where the daemon stands, then the lists — but only when the
    /// daemon can actually answer, so a stopped system costs one cheap ping
    /// instead of three failing XPC calls every two seconds.
    private func tick() async {
        await system.refresh()
        guard system.status.isOperational else { return }
        await containers.refresh()
        await images.refresh()
        // Keeps uptime and status live while the user reads the detail pane.
        await containerDetail.refresh()
    }

    /// Refresh now, from ⌘R or straight after an action.
    func refreshNow() async {
        await poller.tickNow()
    }

    func windowAppeared() { isWindowVisible = true }
    func windowDisappeared() { isWindowVisible = false }
    func menuOpened() { isMenuOpen = true }
    func menuClosed() { isMenuOpen = false }

    /// The window is still "appeared" when minimised or fully covered, so
    /// occlusion is what actually decides whether anyone can see the data.
    func occlusionChanged(isVisible: Bool) {
        isWindowVisible = isVisible
    }

    private func syncPolling() {
        if isWindowVisible || isMenuOpen {
            if !poller.isActive { poller.resume() }
        } else if poller.isActive {
            poller.pause()
        }
    }

    /// A short-lived note about something that succeeded, such as how much
    /// disk a delete actually reclaimed.
    private(set) var statusNote: String?

    func note(reclaimed result: ImageDeletionResult) {
        statusNote =
            result.reclaimedBytes > 0
            ? "Deleted \(result.reference) · reclaimed \(result.reclaimedBytes.formatted(.byteCount(style: .file)))"
            : "Deleted \(result.reference) · no space reclaimed, its layers are shared"
        let note = statusNote
        Task {
            try? await Task.sleep(for: .seconds(6))
            if statusNote == note { statusNote = nil }
        }
    }

    func dismissStatusNote() { statusNote = nil }

    func show(_ error: DockyardError) { notice = error }
    func dismissNotice() { notice = nil }
}
