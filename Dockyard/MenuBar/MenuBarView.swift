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
            } else {
                daemonActions
                Divider().padding(.vertical, 8)
            }

            Button("Open Dockyard") {
                openWindow(id: DockyardApp.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            Button("Quit Dockyard") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .onAppear { model.menuOpened() }
        .onDisappear { model.menuClosed() }
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
                    ContainerStatusBadge(status: container.status)
                    Text(container.id)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    // Stop buttons arrive with the lifecycle actions in T05.
                    if let port = container.ports.first, let url = port.localURL {
                        Link(destination: url) {
                            Image(systemName: "safari")
                        }
                        .help("Open http://localhost:\(port.hostPort)")
                    }
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
