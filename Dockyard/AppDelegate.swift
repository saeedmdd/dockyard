import AppKit
import DockyardCore
import SwiftUI

/// Handles the two things a `Scene` cannot express.
///
/// SwiftUI has no way to say "open without the window" — a `Window` scene is
/// created and shown before any view code runs — so the window is closed once
/// the app has finished launching. And clicking the Dock icon with no window
/// open has to bring one back, which is `applicationShouldHandleReopen`'s job.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read straight from defaults rather than from the model: this runs
        // before any view exists to hand one over, and it is the same store.
        guard MainActor.assumeIsolated({ AppSettings().startsHidden }) else { return }
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.close()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Returning true lets AppKit restore the window it already knows about;
        // the Window scene brings it back on the next activation.
        true
    }

    /// Closing the window leaves the app in the menu bar, which is the point of
    /// having one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
