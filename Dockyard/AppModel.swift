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
    let builds: BuildStore
    let volumes: VolumeStore
    let networks: NetworkStore
    let registry: RegistryStore
    let settings: AppSettings
    let loginItem = LoginItem()

    var selectedSection: SidebarSection = .containers {
        didSet {
            guard selectedSection != oldValue else { return }
            // Each list keeps its own query, but carrying a stale one into a
            // section the user has just switched to hides rows for no visible
            // reason — the field is off screen while they look at the result.
            searchQuery = ""
            Task { await refreshNow() }
        }
    }

    /// What is typed in the current list's search field.
    var searchQuery: String = ""
    var selectedContainerID: ContainerItem.ID? {
        didSet {
            guard selectedContainerID != oldValue else { return }
            Task { await containerDetail.select(selectedContainerID) }
        }
    }
    var selectedVolumeName: String?
    var selectedNetworkName: String?
    var selectedImageID: ImageItem.ID? {
        didSet {
            guard selectedImageID != oldValue else { return }
            Task { await imageDetail.select(selectedImageID) }
        }
    }
    /// Bumped by ⌘⌫ so whichever list is on screen opens its own delete
    /// confirmation. The menu cannot show those dialogs itself — each one is
    /// worded for what it deletes — so it asks rather than tells.
    var deleteSelectionRequest = 0
    /// Bumped by ⌘F, so whichever list is on screen focuses its search field.
    var findRequest = 0
    /// Bumped by ⌘⇧F, for the search inside a container's logs.
    var logSearchFocusRequest = 0

    /// Counters rather than flags, and read on appear as well as on change.
    ///
    /// A menu command switches section and asks for the sheet in the same tick,
    /// so the Images screen usually does not exist yet when the request lands —
    /// its `onChange` never fires. As a flag that also left the request stuck
    /// `true`, which made every later press a no-op and the shortcut dead for
    /// the rest of the session.
    var pullSheetRequest = 0
    var buildSheetRequest = 0
    /// Set by the menu command or an image's Run button; carries the image to
    /// pre-fill when there is one.
    var runSheetRequest: RunSheetRequest?

    /// Polling runs only while the user can see something. Two independent
    /// surfaces can demand it, so they are tracked separately rather than as
    /// one flag that whichever closes last would clear.
    /// Volume names mounted by each container, accumulated as details are
    /// loaded. Listing containers does not include mounts, so this fills in as
    /// the user browses rather than costing a detail fetch per container on
    /// every poll.
    private(set) var mountedVolumesByContainer: [String: Set<String>] = [:]

    func recordMounts(for detail: ContainerDetail) {
        let volumes = Set(detail.mounts.compactMap(\.volumeName))
        mountedVolumesByContainer[detail.id] = volumes
    }

    private var isWindowVisible = false { didSet { syncPolling() } }
    private var isMenuOpen = false { didSet { syncPolling() } }

    /// Exposed so views that drive a session directly (the terminal) can
    /// reach it without a store standing in the middle.
    let backend: any ContainerBackend
    private(set) var poller: Poller!

    init(backend: any ContainerBackend = LiveBackend(), settings: AppSettings = AppSettings()) {
        self.backend = backend
        self.settings = settings
        self.system = SystemStore(backend: backend, cli: CLIRunner(executablePath: settings.resolvedCLIPath))
        self.containers = ContainerStore(backend: backend)
        self.containerDetail = ContainerDetailStore(backend: backend)
        self.logs = LogStore(backend: backend)
        self.stats = StatsStore(backend: backend)
        self.images = ImageStore(backend: backend)
        self.imageDetail = ImageDetailStore(backend: backend)
        self.run = RunStore(backend: backend)
        self.volumes = VolumeStore(backend: backend)
        self.networks = NetworkStore(backend: backend)
        self.registry = RegistryStore(backend: backend)
        self.builds = BuildStore()
        self.images.showsInfrastructure = settings.showsInfrastructureImages
        self.poller = Poller(interval: settings.pollInterval) { [weak self] in
            await self?.tick()
        }
        // The settings object deliberately knows nothing about pollers or image
        // stores; it reports a change and the model decides what that means.
        settings.onPollIntervalChange = { [weak self] interval in
            self?.poller.interval = interval
        }
        settings.onShowInfrastructureChange = { [weak self] shows in
            self?.images.showsInfrastructure = shows
        }
        builds.onSuccess = { [weak self] job in
            guard let self else { return }
            await images.refresh()
            note("Built \(job.spec.trimmedTag.isEmpty ? "image" : job.spec.trimmedTag)")
        }
        builds.onFailure = { [weak self] job in
            self?.show(
                .cliFailed(
                    command: "container build",
                    exitCode: job.exitCode ?? -1,
                    output: job.lastLine ?? ""
                )
            )
        }
        applyCLIPath()
        self.containerDetail.onDetailLoaded = { [weak self] detail in
            self?.recordMounts(for: detail)
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
        if selectedSection == .volumes { await volumes.refresh() }
        if selectedSection == .networks { await networks.refresh() }
        // Disk usage walks the image store, so it is only worth paying for
        // while the panel that shows it is on screen.
        if selectedSection == .system { await system.refreshUsage() }
    }

    /// Names of containers mounting a volume.
    ///
    /// The list only carries a summary per container, so this reads the mount
    /// details the detail store has already fetched, plus the selected one.
    func containersMounting(_ volumeName: String) -> [String] {
        mountedVolumesByContainer
            .filter { $0.value.contains(volumeName) }
            .keys
            .sorted()
    }

    /// Points the two CLI-backed stores at whatever path the settings hold.
    ///
    /// Called at startup and whenever the setting changes. Returns false when a
    /// start or stop is in flight, so the Settings window can say the change
    /// will apply once that finishes rather than pretending it took.
    @discardableResult
    func applyCLIPath() -> Bool {
        let runner = CLIRunner(executablePath: settings.resolvedCLIPath)
        builds.useRunner(runner)
        guard system.useController(runner) else { return false }
        Task { await system.refresh() }
        return true
    }

    /// The container the Containers list has selected, if any.
    var selectedContainer: ContainerItem? {
        selectedContainerID.flatMap { containers.item(id: $0) }
    }

    /// Whether ⌘⌫ has anything to delete in the section on screen. Menu items
    /// that do nothing are worse than menu items that are greyed out.
    var hasDeletableSelection: Bool {
        switch selectedSection {
        case .containers: selectedContainerID != nil
        case .images: selectedImageID != nil
        case .volumes: selectedVolumeName != nil
        case .networks: networks.items.first { $0.name == selectedNetworkName }.map { !$0.isBuiltin } ?? false
        case .system: false
        }
    }

    func requestDeleteSelection() {
        guard hasDeletableSelection else { return }
        deleteSelectionRequest += 1
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

    // MARK: - Toasts

    /// Something worth saying once, without stopping what the user is doing.
    struct Toast: Identifiable, Equatable {
        enum Kind: Equatable {
            case note
            case problem
        }

        let id = UUID()
        let kind: Kind
        let title: String
        /// The unabbreviated text, kept for the System panel and the clipboard.
        let detail: String?
    }

    private(set) var toasts: [Toast] = []

    /// Errors that have been shown, newest first, for the System panel.
    ///
    /// A toast is gone in six seconds, which is not long enough to read a long
    /// upstream message, let alone copy it into a bug report. The panel keeps
    /// them until the app quits.
    private(set) var problems: [Toast] = []
    static let maximumRememberedProblems = 50

    /// Six seconds: long enough to read a line, short enough not to sit over
    /// the list.
    static let toastLifetime = Duration.seconds(6)

    func show(_ error: DockyardError) {
        let toast = Toast(
            kind: .problem,
            title: error.errorDescription ?? "Something went wrong",
            detail: [error.failureReason, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "\n\n")
                .nilIfEmpty
        )
        problems.insert(toast, at: 0)
        if problems.count > Self.maximumRememberedProblems {
            problems.removeLast(problems.count - Self.maximumRememberedProblems)
        }
        present(toast)
    }

    func note(_ text: String) {
        present(Toast(kind: .note, title: text, detail: nil))
    }

    /// A short-lived note about something that succeeded, such as how much
    /// disk a delete actually reclaimed.
    func note(reclaimed result: ImageDeletionResult) {
        note(
            result.reclaimedBytes > 0
                ? "Deleted \(result.reference) · reclaimed \(DiskUsage.label(result.reclaimedBytes))"
                : "Deleted \(result.reference) · no space reclaimed, its layers are shared"
        )
    }

    func dismiss(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }

    func clearProblems() {
        problems.removeAll()
    }

    private func present(_ toast: Toast) {
        toasts.append(toast)
        Task { [weak self] in
            try? await Task.sleep(for: Self.toastLifetime)
            self?.dismiss(toast)
        }
    }

}
