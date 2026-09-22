import DockyardCore
import SwiftUI

/// The lifecycle actions, in one place.
///
/// The toolbar, the row context menu and the menu bar all drive the same
/// commands, so they share this rather than each growing their own copy that
/// drifts — particularly around the delete confirmations.
@MainActor
struct ContainerActions {
    let model: AppModel

    func start(_ container: ContainerItem) {
        Task { await model.containers.start(container.id) }
    }

    func stop(_ container: ContainerItem) {
        Task { await model.containers.stop(container.id) }
    }

    func kill(_ container: ContainerItem, signal: ProcessSignal) {
        Task { await model.containers.kill(container.id, signal: signal) }
    }

    func delete(_ container: ContainerItem, force: Bool) {
        Task { await model.containers.delete(container.id, force: force) }
    }

    func canStart(_ container: ContainerItem) -> Bool {
        container.status == .stopped || container.status == .unknown
    }

    func canStop(_ container: ContainerItem) -> Bool {
        container.status == .running
    }

    func isBusy(_ container: ContainerItem) -> Bool {
        model.containers.pendingAction(for: container.id) != nil
    }
}

/// Context menu for a container row.
struct ContainerContextMenu: View {
    let container: ContainerItem
    let actions: ContainerActions
    @Binding var deletionTarget: ContainerItem?

    var body: some View {
        if actions.canStart(container) {
            Button("Start", systemImage: "play.fill") { actions.start(container) }
        }
        if actions.canStop(container) {
            Button("Stop", systemImage: "stop.fill") { actions.stop(container) }
            Menu("Send Signal") {
                ForEach(ProcessSignal.allCases) { signal in
                    Button(signal.title) { actions.kill(container, signal: signal) }
                        .help(signal.detail)
                }
            }
        }

        Divider()

        if let port = container.ports.first, let url = port.localURL {
            Link("Open http://localhost:\(port.hostPort)", destination: url)
        }
        Button("Copy Name", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        }

        Divider()

        // Always routed through the confirmation sheet: deleting a running
        // container needs force, and that is the user's call, not ours.
        Button("Delete…", systemImage: "trash", role: .destructive) {
            deletionTarget = container
        }
    }
}

/// Confirmation for deleting a container, with different stakes depending on
/// whether it is running.
struct DeleteContainerConfirmation: ViewModifier {
    @Binding var target: ContainerItem?
    let actions: ContainerActions

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map { "Delete “\($0.id)”?" } ?? "Delete container?",
            isPresented: .init(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible,
            presenting: target
        ) { container in
            if container.status == .running {
                Button("Stop and Delete", role: .destructive) {
                    actions.delete(container, force: true)
                    target = nil
                }
            } else {
                Button("Delete", role: .destructive) {
                    actions.delete(container, force: false)
                    target = nil
                }
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { container in
            if container.status == .running {
                Text("This container is running. It will be stopped first, and this cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
    }
}

extension View {
    func deleteContainerConfirmation(
        target: Binding<ContainerItem?>,
        actions: ContainerActions
    ) -> some View {
        modifier(DeleteContainerConfirmation(target: target, actions: actions))
    }
}
