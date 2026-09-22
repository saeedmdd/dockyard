import DockyardCore
import SwiftUI

@main
struct DockyardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("Dockyard", systemImage: "shippingbox") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}
