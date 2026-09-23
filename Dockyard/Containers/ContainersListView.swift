import DockyardCore
import SwiftUI

struct ContainersListView: View {
    @Environment(AppModel.self) private var model
    @State private var isSearchPresented = false
    @State private var sortOrder = [KeyPathComparator(\ContainerItem.id)]
    @State private var deletionTarget: ContainerItem?
    @State private var isConfirmingPrune = false
    @State private var runRequest: RunSheetRequest?

    private var actions: ContainerActions { ContainerActions(model: model) }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if let error = model.containers.actionError {
                ActionErrorBanner(error: error) { model.containers.clearActionError() }
            }

            if model.containers.items.isEmpty {
                EmptyListView(
                    symbol: "shippingbox",
                    title: model.containers.isLoadingInitially ? "Loading…" : "No containers yet",
                    message: model.containers.isLoadingInitially
                        ? nil
                        : "Run an image to create one.",
                    actionTitle: model.containers.isLoadingInitially ? nil : "Run a Container…",
                    action: model.containers.isLoadingInitially
                        ? nil : { runRequest = RunSheetRequest(image: nil) }
                )
            } else if visibleContainers.isEmpty {
                NoSearchResultsView(query: model.searchQuery, noun: "containers") {
                    model.searchQuery = ""
                }
            } else {
                // The detail pane sits beside the table rather than replacing
                // it, so the user keeps their place in the list while reading.
                HSplitView {
                    table
                        .frame(minWidth: 380, idealWidth: 620)
                    if model.selectedContainerID != nil {
                        ContainerDetailView(deletionTarget: $deletionTarget)
                            .frame(minWidth: 340, idealWidth: 420)
                    }
                }
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .searchable(
            text: $model.searchQuery,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Name, image, port, IP"
        )
        // `isPresented` is the only way to put the cursor in the field from a
        // menu command; there is no focus binding for a search field.
        .onChange(of: model.findRequest) { isSearchPresented = true }
        .persistentSort(
            $sortOrder,
            table: .containers,
            columns: [
                "name": KeyPathComparator(\ContainerItem.id),
                "image": KeyPathComparator(\ContainerItem.image),
                "state": KeyPathComparator(\ContainerItem.status.rawValue),
                "started": KeyPathComparator(\ContainerItem.sortableStartDate),
            ]
        )
        .toolbar { toolbarContent }
        .deleteContainerConfirmation(target: $deletionTarget, actions: actions)
        // ⌘⌫ asks; the list opens its own confirmation, worded for what it
        // deletes, rather than the menu trying to own that dialog.
        .onChange(of: model.deleteSelectionRequest) {
            if let selected = model.selectedContainer { deletionTarget = selected }
        }
        .sheet(item: $runRequest) { request in
            RunSheet(image: request.image)
        }
        // Read on appear as well as on change, for the same reason the Images
        // sheets are: ⌘N switches section and asks in one tick, so this view
        // usually does not exist yet when the request lands.
        .onAppear(perform: openRequestedRunSheet)
        .onChange(of: model.runSheetRequest?.id) { openRequestedRunSheet() }
        .confirmationDialog(
            "Delete all stopped containers?",
            isPresented: $isConfirmingPrune,
            titleVisibility: .visible
        ) {
            Button("Delete \(stoppedCount) Container\(stoppedCount == 1 ? "" : "s")", role: .destructive) {
                Task { await model.containers.pruneStopped() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running containers are left alone. This cannot be undone.")
        }
    }

    private var table: some View {
        @Bindable var model = model

        // Sorted at the view rather than in the store, so each poll's fresh
        // data keeps whatever order the user picked.
        return Table(
            visibleContainers.sorted(using: sortOrder),
            selection: $model.selectedContainerID,
            sortOrder: $sortOrder
        ) {
            TableColumn("") { container in
                ContainerStatusBadge(
                    status: container.status,
                    isBusy: actions.isBusy(container)
                )
            }
            .width(18)

            TableColumn("Name", value: \.id) { container in
                Text(container.id)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The state lives in a column of its own as a coloured dot,
                    // so the name carries it for anyone reading row by row.
                    .accessibilityLabel(
                        "\(container.id), \(model.containers.displayStatus(for: container))"
                    )
            }
            .width(min: 120, ideal: 200)

            TableColumn("Image", value: \.image) { container in
                Text(container.image)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 240)

            TableColumn("State", value: \.status.rawValue) { container in
                Text(model.containers.displayStatus(for: container))
                    .foregroundStyle(container.status == .running ? .primary : .secondary)
            }
            .width(80)

            TableColumn("Ports") { container in
                PortsCell(ports: container.ports)
            }
            .width(min: 90, ideal: 150)

            TableColumn("IP") { container in
                Text(container.primaryIPv4 ?? "—")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .width(110)

            TableColumn("Started", value: \.sortableStartDate) { container in
                RelativeDateCell(date: container.startedAt)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: ContainerItem.ID.self) { ids in
            if let id = ids.first, let container = model.containers.item(id: id) {
                ContainerContextMenu(
                    container: container,
                    actions: actions,
                    deletionTarget: $deletionTarget
                )
            }
        } primaryAction: { ids in
            // Double-click toggles: the obvious thing for the obvious gesture.
            guard let id = ids.first, let container = model.containers.item(id: id) else { return }
            if actions.canStart(container) {
                actions.start(container)
            } else if actions.canStop(container) {
                actions.stop(container)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            let selected = model.selectedContainerID.flatMap { model.containers.item(id: $0) }

            Button("Run", systemImage: "plus") {
                runRequest = RunSheetRequest(image: nil)
            }
            .help("Create and run a container")
                .accessibilityLabel("Run a container")

            Button("Start", systemImage: "play.fill") {
                if let selected { actions.start(selected) }
            }
            .disabled(selected.map { !actions.canStart($0) || actions.isBusy($0) } ?? true)
            .help("Start the selected container")
                .accessibilityLabel("Start the selected container")

            Button("Stop", systemImage: "stop.fill") {
                if let selected { actions.stop(selected) }
            }
            .disabled(selected.map { !actions.canStop($0) || actions.isBusy($0) } ?? true)
            .help("Stop the selected container")
                .accessibilityLabel("Stop the selected container")

            Button("Delete", systemImage: "trash") {
                deletionTarget = selected
            }
            .disabled(selected == nil)
            .help("Delete the selected container")
                .accessibilityLabel("Delete the selected container")

            Spacer()

            Button("Clean Up", systemImage: "sparkles") {
                isConfirmingPrune = true
            }
            .disabled(stoppedCount == 0)
            .help("Delete all stopped containers")
                .accessibilityLabel("Delete all stopped containers")
        }
    }

    private func openRequestedRunSheet() {
        guard let request = model.runSheetRequest else { return }
        runRequest = request
        model.runSheetRequest = nil
    }

    /// The rows the search leaves.
    private var visibleContainers: [ContainerItem] {
        model.containers.items.matching(model.searchQuery)
    }

    private var stoppedCount: Int {
        model.containers.items.count { $0.status == .stopped }
    }

    private var subtitle: String {
        let total = model.containers.items.count
        guard total > 0 else { return "" }
        let shown = visibleContainers.count
        // While searching, the count that matters is how many are on screen —
        // but the total has to stay visible or the list looks like it lost rows.
        if shown != total {
            return "\(shown) of \(total) shown"
        }
        return "\(model.containers.running.count) running of \(total)"
    }
}

/// Coloured dot for a container's state, pulsing while an action is in flight.
struct ContainerStatusBadge: View {
    let status: ContainerStatus
    var isBusy = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isBusy ? 0.35 : 1)
            .overlay {
                if isBusy {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 2)
                        .scaleEffect(1.9)
                }
            }
            .accessibilityLabel(accessibilityDescription)
    }

    /// Read aloud in place of a coloured dot, which VoiceOver cannot describe.
    /// "Running" alone is ambiguous next to a name; saying what is running, and
    /// that an action is under way, is what a sighted user gets from the pulse.
    private var accessibilityDescription: String {
        let state =
            switch status {
            case .running: "Running"
            case .stopping: "Stopping"
            case .stopped: "Stopped"
            case .unknown: "State unknown"
            }
        return isBusy ? "\(state), working" : state
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .stopping: .orange
        case .stopped: .secondary
        case .unknown: .yellow
        }
    }
}

/// Shows a failed action until the user dismisses it.
///
/// Deliberately not a row-level indicator: by the time a start fails the list
/// has refreshed, and the container may not even be there any more.
struct ActionErrorBanner: View {
    let error: DockyardError
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "Something went wrong")
                    .font(.callout.weight(.medium))
                if let reason = error.failureReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Published ports, with the host port clickable when it might serve HTTP.
struct PortsCell: View {
    let ports: [PortMapping]

    var body: some View {
        if ports.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(ports.prefix(2)) { port in
                    if let url = port.localURL {
                        Link("\(port.hostPort)→\(port.containerPort)", destination: url)
                            .font(.callout)
                    } else {
                        Text("\(port.hostPort)→\(port.containerPort)/\(port.networkProtocol)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if ports.count > 2 {
                    Text("+\(ports.count - 2)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct RelativeDateCell: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .foregroundStyle(.secondary)
                .help(date.formatted(date: .abbreviated, time: .standard))
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

struct EmptyListView: View {
    let symbol: String
    let title: String
    var message: String?
    /// The one thing worth doing from an empty list — pulling an image, running
    /// a container. Omitted where there is nothing sensible to offer, such as
    /// while a list is still loading.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when a search hides everything, in place of a list's own empty state.
///
/// Distinct wording matters: "No containers yet" next to a full search field
/// reads as if the containers were deleted.
struct NoSearchResultsView: View {
    let query: String
    let noun: String
    let clear: () -> Void

    var body: some View {
        EmptyListView(
            symbol: "magnifyingglass",
            title: "No \(noun) match “\(query)”",
            message: "Every word has to appear somewhere in the row.",
            actionTitle: "Clear Search",
            action: clear
        )
    }
}
