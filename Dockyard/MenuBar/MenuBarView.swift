import DockyardCore
import SwiftUI

/// Menu bar panel. T04 adds the running-container list and quick stop actions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(status: model.system.status)
                Text(model.system.status.summary)
                    .font(.headline)
            }

            if let health = model.system.status.health {
                Text("container \(health.semanticVersion ?? health.apiServerVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch model.system.status {
            case .stopped:
                Button("Start container system") { model.system.start() }
            case .cliMissing:
                Link("Install container…", destination: URL(string: "https://github.com/apple/container/releases")!)
            default:
                EmptyView()
            }

            Divider()

            Button("Open Dockyard") {
                openWindow(id: DockyardApp.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit Dockyard") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .task { await model.system.refresh() }
    }
}
