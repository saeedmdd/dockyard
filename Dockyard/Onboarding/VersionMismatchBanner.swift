import DockyardCore
import SwiftUI

/// Shown above the main UI when `container-apiserver` is a different version
/// from the client libraries this build links.
///
/// Deliberately non-blocking: the protocols usually still line up, and locking
/// the user out of their containers over a version string would be worse than
/// the risk. Dismissal lasts for the session only.
struct VersionMismatchBanner: View {
    let server: String
    let client: String
    @Binding var isDismissed: Bool

    var body: some View {
        if !isDismissed {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Container version mismatch")
                        .font(.callout.weight(.semibold))
                    Text(
                        "The running container system is \(server), but Dockyard was built against "
                            + "\(client). Most things should work; if something behaves oddly, update one of them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Continue anyway") { isDismissed = true }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
