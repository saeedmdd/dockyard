import DockyardCore
import SwiftUI

@main
struct DockyardApp: App {
    static let mainWindowID = "dockyard.main"

    @State private var model = AppModel()

    var body: some Scene {
        Window("Dockyard", id: Self.mainWindowID) {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await model.refreshNow() }
                }
                .keyboardShortcut("r")
            }
            SidebarCommands()
        }

        MenuBarExtra("Dockyard", systemImage: "shippingbox") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
