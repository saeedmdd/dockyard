import DockyardCore
import SwiftUI

/// Raw configuration and runtime state as JSON, matching `container inspect`.
///
/// Also used for images in T10, so it takes plain text rather than a container.
struct InspectView: View {
    let json: String?
    let title: String

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            if let json {
                ScrollView([.vertical, .horizontal]) {
                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Text("\(json.count.formatted()) characters")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            didCopy = false
                        }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy JSON", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copy JSON for \(title)")
                }
                .padding(10)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
