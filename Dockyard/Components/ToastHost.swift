import DockyardCore
import SwiftUI

/// The one place transient messages appear.
///
/// Errors from a background action have nowhere good to go: the row they
/// belong to may already have been refreshed away, and a modal for something
/// the user did not initiate is worse than the error. A toast says it once and
/// leaves; the System panel keeps the full text for as long as the app runs.
struct ToastHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastView(toast: toast) {
                    model.dismiss(toast)
                } reveal: {
                    model.dismiss(toast)
                    model.selectedSection = .system
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Without this the invisible container swallows clicks on the list
        // underneath it whenever no toast is showing.
        .allowsHitTesting(!model.toasts.isEmpty)
        .animation(.snappy, value: model.toasts)
    }
}

private struct ToastView: View {
    let toast: AppModel.Toast
    let dismiss: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isProblem ? .orange : .green)
            Text(toast.title)
                .lineLimit(2)
                .textSelection(.enabled)
            if isProblem {
                Button("Details", action: reveal)
                    .buttonStyle(.link)
                    .help("Show the full message in the System panel")
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Dismiss this message")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(radius: 8, y: 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private var isProblem: Bool { toast.kind == .problem }
}
