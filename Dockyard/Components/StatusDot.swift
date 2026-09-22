import DockyardCore
import SwiftUI

/// The coloured dot used for daemon state in the menu bar, the System panel and
/// the onboarding header.
struct StatusDot: View {
    let status: DaemonStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if status.isTransitioning {
                    Circle()
                        .stroke(color.opacity(0.35), lineWidth: 3)
                        .scaleEffect(1.8)
                }
            }
            .accessibilityLabel(status.summary)
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .versionMismatch: .yellow
        case .starting, .stopping: .orange
        case .stopped: .secondary
        case .cliMissing: .red
        case .unknown: .secondary
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        ForEach(
            [
                DaemonStatus.running(.init(
                    apiServerVersion: "1.0.0", apiServerCommit: "abc", apiServerBuild: "release",
                    appName: "container-apiserver", appRoot: URL(fileURLWithPath: "/"),
                    installRoot: URL(fileURLWithPath: "/"), logRoot: nil)),
                .stopped, .starting, .cliMissing(path: "/usr/local/bin/container"),
            ],
            id: \.summary
        ) { status in
            HStack {
                StatusDot(status: status)
                Text(status.summary)
            }
        }
    }
    .padding()
}
