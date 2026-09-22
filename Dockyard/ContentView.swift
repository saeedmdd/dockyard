import DockyardCore
import SwiftUI

/// Routes between onboarding and the app proper.
///
/// T04 replaces `readyPlaceholder` with the real sidebar, lists and poller.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var mismatchDismissed = false
    @State private var isConfirmingStop = false

    var body: some View {
        VStack(spacing: 0) {
            if case .versionMismatch(let server, let client, _) = model.system.status {
                VersionMismatchBanner(server: server, client: client, isDismissed: $mismatchDismissed)
            }

            if model.system.status.isOperational {
                readyPlaceholder
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .task { await model.bootstrap() }
    }

    private var readyPlaceholder: some View {
        VStack(spacing: 10) {
            StatusDot(status: model.system.status, size: 14)
            Text("Container system is running")
                .font(.title2)
            if let health = model.system.status.health {
                Text("apiserver \(health.semanticVersion ?? health.apiServerVersion) · \(health.shortCommit)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Containers and images arrive in T04.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Stop container system") {
                isConfirmingStop = true
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Stop the container system?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) { model.system.stop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Upstream stops every running container before booting out the
            // service, so this is never just "quit the daemon".
            Text("Every running container will be stopped first.")
        }
    }
}
