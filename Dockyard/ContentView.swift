import AppKit
import DockyardCore
import SwiftUI

/// Routes between onboarding and the app proper, and owns the poll lifecycle.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var mismatchDismissed = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if case .versionMismatch(let server, let client, _) = model.system.status {
                VersionMismatchBanner(server: server, client: client, isDismissed: $mismatchDismissed)
            }

            if model.system.status.isOperational {
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    detail
                }
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 860, minHeight: 500)
        .task { await model.refreshNow() }
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowDisappeared() }
        // A minimised or fully covered window is still "appeared", so occlusion
        // is what actually tells us whether anyone can see the data.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeOcclusionStateNotification)) { _ in
            model.occlusionChanged(isVisible: NSApp.occlusionState.contains(.visible))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSection {
        case .containers:
            ContainersListView()
        case .images:
            ImagesListView()
        case .volumes:
            VolumesListView()
        case .networks, .system:
            ComingSoonView(section: model.selectedSection)
        }
    }
}

/// Placeholder for sections whose screens arrive in M4.
struct ComingSoonView: View {
    let section: SidebarSection

    var body: some View {
        EmptyListView(
            symbol: section.symbol,
            title: section.title,
            message: "This screen arrives in a later milestone."
        )
        .navigationTitle(section.title)
    }
}
