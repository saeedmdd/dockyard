import DockyardCore
import SwiftUI

/// What the user sees when the container system cannot serve requests.
///
/// Three distinct situations, deliberately worded differently, because the fix
/// differs: nothing installed, installed but stopped, or a transition in
/// progress.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .frame(maxWidth: 440)
            if !model.system.transcript.isEmpty {
                TranscriptView(lines: model.system.transcript)
                    .frame(maxWidth: 560, maxHeight: 180)
                    .padding(.top, 24)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    @ViewBuilder
    private var content: some View {
        switch model.system.status {
        case .unknown:
            checking
        case .cliMissing(let path):
            notInstalled(path: path)
        case .stopped:
            stopped
        case .starting:
            transitioning(title: "Starting the container system…")
        case .stopping:
            transitioning(title: "Stopping the container system…")
        case .running, .versionMismatch:
            // Never shown: ContentView switches to the main UI in these states.
            EmptyView()
        }
    }

    private var checking: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking the container system…")
                .foregroundStyle(.secondary)
        }
    }

    private func notInstalled(path: String) -> some View {
        messageCard(
            icon: "shippingbox",
            tint: .red,
            title: "Apple’s container runtime isn’t installed",
            message: """
                Dockyard is a front end for Apple’s `container` runtime — it doesn’t bundle it. \
                Install the package, then come back.
                """,
            detail: "Looked for it at \(path)"
        ) {
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/apple/container/releases")!) {
                    Label("Download container", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Download container")

                Button("Check again") {
                    Task { await model.system.refresh() }
                }
            }
        }
    }

    private var stopped: some View {
        messageCard(
            icon: "stop.circle",
            tint: .secondary,
            title: "The container system isn’t running",
            message: "Start it to see your containers and images. This registers "
                + "`container-apiserver` with launchd, so it comes back after a reboot.",
            detail: model.system.lastError?.errorDescription
        ) {
            Button {
                model.system.start()
            } label: {
                Label("Start container system", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            // A `Label` inside a button exposes no accessibility name of its
            // own, which leaves the primary action unreadable to VoiceOver.
            .accessibilityLabel("Start container system")
        }
    }

    private func transitioning(title: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(title)
                .font(.title3)
            Button("Cancel") {
                model.system.cancelOperation()
            }
            .buttonStyle(.link)
        }
    }

    private func messageCard(
        icon: String,
        tint: Color,
        title: String,
        message: String,
        detail: String?,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(tint)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            actions()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Live output of a `system start` / `system stop`.
///
/// A plain scrolling list is fine here: these commands emit a handful of lines.
/// Container logs, which run to six figures, get the `NSTextView`-backed view in
/// T07 instead.
struct TranscriptView: View {
    let lines: [CLILine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.stream == .stderr ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) {
                if let last = lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
