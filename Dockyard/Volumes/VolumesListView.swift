import DockyardCore
import SwiftUI

struct VolumesListView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\VolumeItem.name)]
    @State private var isShowingCreateSheet = false
    @State private var deletionTarget: VolumeItem?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if let error = model.volumes.actionError {
                ActionErrorBanner(error: error) { model.volumes.clearActionError() }
            }

            if model.volumes.items.isEmpty {
                EmptyListView(
                    symbol: "externaldrive",
                    title: model.volumes.isLoadingInitially ? "Loading…" : "No volumes yet",
                    message: model.volumes.isLoadingInitially
                        ? nil
                        : "Volumes keep data that outlives the container using it."
                )
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    table
                        .frame(minWidth: 380, idealWidth: 620)
                    if let selected = selectedVolume {
                        VolumeDetailView(volume: selected, deletionTarget: $deletionTarget)
                            .frame(minWidth: 300, idealWidth: 360)
                    }
                }
            }
        }
        .navigationTitle("Volumes")
        .navigationSubtitle(model.volumes.items.isEmpty ? "" : "\(model.volumes.items.count) volumes")
        .toolbar {
            Button("New Volume", systemImage: "plus") {
                isShowingCreateSheet = true
            }
            .help("Create a volume")

            Button("Delete", systemImage: "trash") {
                deletionTarget = selectedVolume
            }
            .disabled(selectedVolume == nil)
            .help("Delete the selected volume")
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateVolumeSheet()
        }
        .deleteVolumeConfirmation(target: $deletionTarget)
    }

    private var selectedVolume: VolumeItem? {
        model.selectedVolumeName.flatMap { name in
            model.volumes.items.first { $0.name == name }
        }
    }

    private var table: some View {
        @Bindable var model = model

        return Table(
            model.volumes.items.sorted(using: sortOrder),
            selection: $model.selectedVolumeName,
            sortOrder: $sortOrder
        ) {
            TableColumn("Name", value: \.name) { volume in
                Text(volume.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Driver") { volume in
                Text(volume.driver).foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Used") { volume in
                UsageCell(volume: volume)
            }
            .width(90)

            TableColumn("Used by") { volume in
                UsedByCell(volume: volume)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Created") { volume in
                RelativeDateCell(date: volume.createdAt)
            }
            .width(100)
        }
    }
}

/// A volume's size, fetched the first time its row is drawn.
///
/// Each size is a separate call to the runtime, so pricing the whole list on
/// every poll would be wasteful for a column most people glance at once.
struct UsageCell: View {
    let volume: VolumeItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let bytes = model.volumes.diskUsage[volume.name] {
                Text(bytes.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    .foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .task(id: volume.name) {
            await model.volumes.loadDiskUsage(for: volume.name)
        }
    }
}

/// Containers that mount this volume.
struct UsedByCell: View {
    let volume: VolumeItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let users = model.containersMounting(volume.name)
        if users.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            Text(users.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(users.joined(separator: "\n"))
        }
    }
}

struct VolumeDetailView: View {
    let volume: VolumeItem
    @Binding var deletionTarget: VolumeItem?
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "externaldrive")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(volume.name)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(volume.driver)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete…", systemImage: "trash") { deletionTarget = volume }
                        .buttonStyle(.bordered)
                }

                section("Details") {
                    if let bytes = model.volumes.diskUsage[volume.name] {
                        LabeledContent("Used", value: bytes.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    }
                    if let declared = volume.sizeInBytes {
                        LabeledContent("Size", value: declared.formatted(.byteCount(style: .file)))
                    }
                    LabeledContent("Format", value: volume.format)
                    LabeledContent("Created") {
                        Text(volume.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    CopyableRow(label: "Path", value: volume.source, isMonospaced: true)
                }

                let users = model.containersMounting(volume.name)
                section("Used by") {
                    if users.isEmpty {
                        Text("No containers mount this volume.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(users, id: \.self) { name in
                            Text(name).font(.callout)
                        }
                    }
                }

                if !volume.labels.isEmpty {
                    section("Labels") {
                        ForEach(volume.labels.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: volume.labels[key] ?? "")
                        }
                    }
                }

                if !volume.options.isEmpty {
                    section("Options") {
                        ForEach(volume.options.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: volume.options[key] ?? "")
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

struct CreateVolumeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var spec = VolumeSpec()
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New volume")
                .font(.title3.weight(.semibold))

            LabeledField("Name", required: true) {
                TextField("data", text: $spec.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(create)
            }

            KeyValueListEditor(title: "label", pairs: $spec.labels)

            Text("Volumes outlive the containers that use them.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .frame(width: 420)
        .onAppear { isNameFocused = true }
    }

    private func create() {
        guard spec.isValid else { return }
        let spec = spec
        Task {
            if let created = await model.volumes.create(spec) {
                model.selectedVolumeName = created.name
            }
        }
        dismiss()
    }
}

/// Confirmation for deleting a volume, which says plainly when containers
/// depend on it.
struct DeleteVolumeConfirmation: ViewModifier {
    @Binding var target: VolumeItem?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map { "Delete “\($0.name)”?" } ?? "Delete volume?",
            isPresented: .init(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible,
            presenting: target
        ) { volume in
            Button("Delete", role: .destructive) {
                Task { await model.volumes.delete(volume.name) }
                target = nil
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { volume in
            let users = model.containersMounting(volume.name)
            if users.isEmpty {
                Text("Everything stored in this volume is deleted with it. This cannot be undone.")
            } else {
                Text(
                    """
                    \(users.count == 1 ? "A container mounts" : "\(users.count) containers mount") this volume — \
                    \(users.sorted().prefix(3).joined(separator: ", "))\(users.count > 3 ? "…" : ""). \
                    Everything stored in it is deleted, and \(users.count == 1 ? "that container" : "those containers") \
                    will no longer start.
                    """
                )
            }
        }
    }
}

extension View {
    func deleteVolumeConfirmation(target: Binding<VolumeItem?>) -> some View {
        modifier(DeleteVolumeConfirmation(target: target))
    }
}
