import DockyardCore
import SwiftUI

/// Confirmation for deleting an image, which changes shape when containers
/// depend on it.
///
/// Deleting an image a container was created from does not fail — the runtime
/// allows it — but it leaves that container unable to start, with an error that
/// gives no hint about what happened. Naming the containers first is the whole
/// point of this dialog.
struct DeleteImageConfirmation: ViewModifier {
    @Binding var target: ImageItem?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map { "Delete “\($0.displayReference)”?" } ?? "Delete image?",
            isPresented: .init(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible,
            presenting: target
        ) { image in
            Button("Delete", role: .destructive) {
                Task {
                    if let result = await model.images.delete(image.reference) {
                        model.note(reclaimed: result)
                    }
                }
                target = nil
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { image in
            let users = model.images.containersUsing(image, in: model.containers.items)
            if users.isEmpty {
                Text("Layers shared with other images are kept.")
            } else {
                Text(
                    """
                    \(users.count == 1 ? "A container was" : "\(users.count) containers were") created from this \
                    image — \(users.map(\.id).sorted().prefix(3).joined(separator: ", "))\(users.count > 3 ? "…" : ""). \
                    \(users.count == 1 ? "It" : "They") will no longer start.
                    """
                )
            }
        }
    }
}

extension View {
    func deleteImageConfirmation(target: Binding<ImageItem?>) -> some View {
        modifier(DeleteImageConfirmation(target: target))
    }
}

/// A brief confirmation that something worked, such as space reclaimed.
struct StatusNoteBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.callout)
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}
