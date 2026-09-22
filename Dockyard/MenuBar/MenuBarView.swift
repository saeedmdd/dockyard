import DockyardCore
import SwiftUI

/// Placeholder menu bar content. T04 fills in daemon state and running containers.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dockyard")
                .font(.headline)
            Text("container \(DockyardCore.linkedContainerVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit Dockyard") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}
