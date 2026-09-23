import DockyardCore
import SwiftUI

@main
struct DockyardApp: App {
    static let mainWindowID = "dockyard.main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Dockyard", id: Self.mainWindowID) {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { DockyardCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra("Dockyard", systemImage: "shippingbox") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
