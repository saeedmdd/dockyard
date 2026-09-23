import DockyardCore
import SwiftUI

struct NetworksListView: View {
    @Environment(AppModel.self) private var model
    @State private var isSearchPresented = false
    @State private var sortOrder = [KeyPathComparator(\NetworkItem.name)]
    @State private var isShowingCreateSheet = false
    @State private var deletionTarget: NetworkItem?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if let error = model.networks.actionError {
                ActionErrorBanner(error: error) { model.networks.clearActionError() }
            }

            if model.networks.items.isEmpty {
                EmptyListView(
                    symbol: "network",
                    title: model.networks.isLoadingInitially ? "Loading…" : "No networks",
                    message: model.networks.isLoadingInitially
                        ? nil
                        : "Containers share a network to reach each other by name.",
                    actionTitle: model.networks.isLoadingInitially ? nil : "New Network…",
                    action: model.networks.isLoadingInitially ? nil : { isShowingCreateSheet = true }
                )
                .frame(maxHeight: .infinity)
            } else if visibleNetworks.isEmpty {
                NoSearchResultsView(query: model.searchQuery, noun: "networks") {
                    model.searchQuery = ""
                }
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    table
                        .frame(minWidth: 380, idealWidth: 620)
                    if let selected = selectedNetwork {
                        NetworkDetailView(network: selected, deletionTarget: $deletionTarget)
                            .frame(minWidth: 300, idealWidth: 360)
                    }
                }
            }
        }
        .navigationTitle("Networks")
        .navigationSubtitle(networksSubtitle)
        .searchable(
            text: $model.searchQuery,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Name, subnet, gateway"
        )
        // `isPresented` is the only way to put the cursor in the field from a
        // menu command; there is no focus binding for a search field.
        .onChange(of: model.findRequest) { isSearchPresented = true }
        .persistentSort(
            $sortOrder,
            table: .networks,
            columns: [
                "name": KeyPathComparator(\NetworkItem.name),
                "mode": KeyPathComparator(\NetworkItem.mode.rawValue),
            ]
        )
        .toolbar {
            Button("New Network", systemImage: "plus") { isShowingCreateSheet = true }
                .help("Create a network")
                .accessibilityLabel("Create a network")

            Button("Delete", systemImage: "trash") { deletionTarget = selectedNetwork }
                .accessibilityLabel("Delete the selected network")
                .disabled(selectedNetwork == nil || selectedNetwork?.isBuiltin == true)
                .help(
                    selectedNetwork?.isBuiltin == true
                        ? "The container runtime uses this network itself"
                        : "Delete the selected network"
                )
        }
        .sheet(isPresented: $isShowingCreateSheet) { CreateNetworkSheet() }
        .deleteNetworkConfirmation(target: $deletionTarget)
        .onChange(of: model.deleteSelectionRequest) {
            if let selected = selectedNetwork, !selected.isBuiltin { deletionTarget = selected }
        }
    }

    private var visibleNetworks: [NetworkItem] {
        model.networks.items.matching(model.searchQuery)
    }

    private var networksSubtitle: String {
        let total = model.networks.items.count
        guard total > 0 else { return "" }
        let shown = visibleNetworks.count
        return shown == total ? "\(total) networks" : "\(shown) of \(total) shown"
    }

    private var selectedNetwork: NetworkItem? {
        model.selectedNetworkName.flatMap { name in
            model.networks.items.first { $0.name == name }
        }
    }

    private var table: some View {
        @Bindable var model = model

        return Table(
            visibleNetworks.sorted(using: sortOrder),
            selection: $model.selectedNetworkName,
            sortOrder: $sortOrder
        ) {
            TableColumn("Name", value: \.name) { network in
                HStack(spacing: 6) {
                    Text(network.name)
                        .fontWeight(.medium)
                    if network.isBuiltin {
                        Image(systemName: "lock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Used by the container runtime")
                    }
                }
            }
            .width(min: 140, ideal: 200)

            TableColumn("Mode", value: \.mode.rawValue) { network in
                Text(network.mode.title).foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Subnet") { network in
                Text(network.subnet ?? "—")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .width(140)

            TableColumn("Containers") { network in
                let users = model.networks.containersOn(network, in: model.containers.items)
                if users.isEmpty {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    Text(users.map(\.id).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(users.map(\.id).joined(separator: "\n"))
                }
            }
            .width(min: 100, ideal: 180)
        }
    }
}

struct NetworkDetailView: View {
    let network: NetworkItem
    @Binding var deletionTarget: NetworkItem?
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(network.name)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(network.mode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete…", systemImage: "trash") { deletionTarget = network }
                        .buttonStyle(.bordered)
                        .disabled(network.isBuiltin)
                }

                section("Addressing") {
                    LabeledContent("Mode", value: network.mode.title)
                    if let subnet = network.subnet {
                        CopyableRow(label: "Subnet", value: subnet, isMonospaced: true)
                    }
                    if let gateway = network.gateway {
                        CopyableRow(label: "Gateway", value: gateway, isMonospaced: true)
                    }
                    LabeledContent("Created") {
                        Text(network.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }

                let users = model.networks.containersOn(network, in: model.containers.items)
                section("Containers") {
                    if users.isEmpty {
                        Text("No containers are attached.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(users) { container in
                            HStack(spacing: 8) {
                                ContainerStatusBadge(status: container.status)
                                Text(container.id).font(.callout)
                                Spacer()
                                if let ip = container.networks.first(where: { $0.network == network.name })?.ipv4Address {
                                    Text(ip)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                if !network.labels.isEmpty {
                    section("Labels") {
                        ForEach(network.labels.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: network.labels[key] ?? "")
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 5) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct CreateNetworkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var spec = NetworkSpec()
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New network")
                .font(.title3.weight(.semibold))

            LabeledField("Name", required: true) {
                TextField("backend", text: $spec.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(create)
            }

            Picker("Mode", selection: $spec.mode) {
                ForEach(NetworkItem.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Text(spec.mode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledField("Subnet") {
                TextField("Chosen automatically", text: $spec.subnet)
                    .textFieldStyle(.roundedBorder)
            }

            KeyValueListEditor(title: "label", pairs: $spec.labels)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let problem = spec.validationProblems.first, !spec.trimmedName.isEmpty {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!spec.isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isNameFocused = true }
    }

    private func create() {
        guard spec.isValid else { return }
        let spec = spec
        Task {
            if let created = await model.networks.create(spec) {
                model.selectedNetworkName = created.name
            }
        }
        dismiss()
    }
}

/// Confirmation for deleting a network, naming the containers on it.
struct DeleteNetworkConfirmation: ViewModifier {
    @Binding var target: NetworkItem?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map { "Delete “\($0.name)”?" } ?? "Delete network?",
            isPresented: .init(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible,
            presenting: target
        ) { network in
            Button("Delete", role: .destructive) {
                Task { await model.networks.delete(network.name) }
                target = nil
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { network in
            let users = model.networks.containersOn(network, in: model.containers.items)
            if users.isEmpty {
                Text("This cannot be undone.")
            } else {
                Text(
                    """
                    \(users.count == 1 ? "A container is" : "\(users.count) containers are") attached — \
                    \(users.map(\.id).sorted().prefix(3).joined(separator: ", "))\(users.count > 3 ? "…" : ""). \
                    \(users.count == 1 ? "It" : "They") will no longer start.
                    """
                )
            }
        }
    }
}

extension View {
    func deleteNetworkConfirmation(target: Binding<NetworkItem?>) -> some View {
        modifier(DeleteNetworkConfirmation(target: target))
    }
}
