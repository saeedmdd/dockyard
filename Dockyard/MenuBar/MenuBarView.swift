import DockyardCore
import SwiftUI

/// The menu bar panel: daemon state at a glance and the running containers.
///
/// This is the reason people leave an app like this running, so it has to work
/// with the main window closed — including keeping its own data fresh.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)

            if model.system.status.isOperational {
                runningContainers
                Divider().padding(.vertical, 8)
                quickActions
                Divider().padding(.vertical, 8)
            } else {
                daemonActions
                Divider().padding(.vertical, 8)
            }

            Button("Open Dockyard") {
                open(.containers)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Dockyard")
            Button("Quit Dockyard") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quit Dockyard")
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .onAppear { model.menuOpened() }
        .onDisappear { model.menuClosed() }
    }

    /// The two things worth starting from the menu bar with the window closed,
    /// plus a way into the panel that manages the runtime itself.
    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Run Container…") {
                model.runSheetRequest = RunSheetRequest(image: nil)
                open(.containers)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run Container")

            Button("Pull Image…") {
                model.pullSheetRequest += 1
                open(.images)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pull Image")

            Button("System…") {
                open(.system)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the System panel")
        }
    }

    /// Opens the window on a section and brings the app forward.
    ///
    /// Both halves are needed: `openWindow` alone leaves the window behind
    /// whatever the user was doing, since a menu bar click does not activate
    /// the app.
    private func open(_ section: SidebarSection) {
        model.selectedSection = section
        openWindow(id: DockyardApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(status: model.system.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.system.status.summary)
                    .font(.headline)
                if let health = model.system.status.health {
                    Text("container \(health.semanticVersion ?? health.apiServerVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var daemonActions: some View {
        switch model.system.status {
        case .stopped:
            Button("Start container system") { model.system.start() }
                .buttonStyle(.plain)
                .accessibilityLabel("Start the container system")
        case .cliMissing:
            Link("Install container…", destination: URL(string: "https://github.com/apple/container/releases")!)
        case .starting, .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.system.status.summary).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var runningContainers: some View {
        let running = model.containers.running
        if running.isEmpty {
            Text("No containers running")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("Running")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(running.prefix(8)) { container in
                HStack(spacing: 7) {
                    ContainerStatusBadge(
                        status: container.status,
                        isBusy: model.containers.pendingAction(for: container.id) != nil
                    )
                    Text(container.id)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let port = container.ports.first, let url = port.localURL {
                        Link(destination: url) {
                            Image(systemName: "safari")
                        }
                        .help("Open http://localhost:\(port.hostPort)")
                    }
                    Button {
                        // With the window closed the list's error banner has
                        // nowhere to appear, so a failure here has to say so
                        // itself.
                        Task {
                            if await !model.containers.stop(container.id),
                                let error = model.containers.actionError
                            {
                                model.show(error)
                            }
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.containers.pendingAction(for: container.id) != nil)
                    .help("Stop \(container.id)")
                    .accessibilityLabel("Stop \(container.id)")
                }
                .font(.callout)
            }
            if running.count > 8 {
                Text("and \(running.count - 8) more…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
