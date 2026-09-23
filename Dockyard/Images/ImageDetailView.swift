import DockyardCore
import SwiftUI

struct ImageDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .overview
    @State private var selectedVariant: String?
    @Binding var tagTarget: ImageItem?
    @Binding var pushTarget: ImageItem?
    @Binding var deletionTarget: ImageItem?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case inspect = "Inspect"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "info.circle"
            case .inspect: "curlybraces"
            }
        }
    }

    private var store: ImageDetailStore { model.imageDetail }

    var body: some View {
        Group {
            if let detail = store.detail {
                content(detail)
            } else if store.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyListView(
                    symbol: "sidebar.right",
                    title: "No image selected",
                    message: store.lastError?.errorDescription
                )
            }
        }
        .task(id: tab) {
            if tab == .inspect { await store.loadInspectJSON() }
        }
    }

    private func content(_ detail: ImageDetail) -> some View {
        VStack(spacing: 0) {
            header(detail)
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()

            switch tab {
            case .overview:
                overview(detail)
            case .inspect:
                InspectView(json: store.inspectJSON, title: detail.displayReference)
            }
        }
    }

    private func header(_ detail: ImageDetail) -> some View {
        let item = model.images.items.first { $0.reference == detail.reference }

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(detail.displayReference)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(detail.totalSizeBytes.formatted(.byteCount(style: .file)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let created = detail.createdAt, created.timeIntervalSince1970 > 0 {
                    Text("Built \(created.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let item {
                HStack(spacing: 8) {
                    Button("Run…", systemImage: "play.fill") {
                        model.runSheetRequest = RunSheetRequest(image: item)
                    }
                    .help("Create a container from this image")
                    Button("Push…", systemImage: "arrow.up.circle") { pushTarget = item }
                        .help("Push this image to its registry")
                    Button("Tag…", systemImage: "tag") { tagTarget = item }
                    Button("Delete…", systemImage: "trash") { deletionTarget = item }
                        .disabled(item.isInfrastructure)
                        .help(
                            item.isInfrastructure
                                ? "The container runtime uses this image itself"
                                : "Delete this image"
                        )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
    }

    private func overview(_ detail: ImageDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Reference") {
                    CopyableRow(label: "Full name", value: detail.reference, isMonospaced: true)
                    CopyableRow(label: "Digest", value: detail.digest, isMonospaced: true)
                    LabeledContent("Media type", value: detail.mediaType)
                }

                section("Platforms") {
                    // An image usually carries several builds; the one this Mac
                    // would actually run is marked, since it is the one whose
                    // size and command matter here.
                    ForEach(detail.variants) { variant in
                        HStack(spacing: 8) {
                            Image(systemName: variant.isNative ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(variant.isNative ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(variant.platform)
                                    .font(.callout)
                                Text(variant.shortDigest)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(variant.sizeBytes.formatted(.byteCount(style: .file)))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                        .help(variant.isNative ? "Runs natively on this Mac" : "Runs under emulation")
                    }
                }

                if let variant = detail.preferredVariant {
                    section("Defaults for \(variant.platform)") {
                        if !variant.entrypoint.isEmpty {
                            CopyableRow(
                                label: "Entrypoint",
                                value: variant.entrypoint.joined(separator: " "),
                                isMonospaced: true
                            )
                        }
                        if !variant.command.isEmpty {
                            CopyableRow(
                                label: "Command",
                                value: variant.command.joined(separator: " "),
                                isMonospaced: true
                            )
                        }
                        if let directory = variant.workingDirectory, !directory.isEmpty {
                            LabeledContent("Working directory", value: directory)
                        }
                        if let user = variant.user, !user.isEmpty {
                            LabeledContent("User", value: user)
                        }
                        if let signal = variant.stopSignal {
                            LabeledContent("Stop signal", value: signal)
                        }
                        if variant.entrypoint.isEmpty && variant.command.isEmpty {
                            Text("This image declares no default command.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !variant.environment.isEmpty {
                        section("Environment") {
                            ForEach(variant.environment.keys.sorted(), id: \.self) { key in
                                CopyableRow(
                                    label: key,
                                    value: variant.environment[key] ?? "",
                                    isMonospaced: true
                                )
                            }
                        }
                    }

                    if !variant.labels.isEmpty {
                        section("Labels") {
                            ForEach(variant.labels.keys.sorted(), id: \.self) { key in
                                LabeledContent(key, value: variant.labels[key] ?? "")
                            }
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
            VStack(alignment: .leading, spacing: 5) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Adds another reference pointing at the same image.
struct TagImageSheet: View {
    let image: ImageItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newReference = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tag image")
                .font(.title3.weight(.semibold))
            Text(image.displayReference)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            TextField("New reference", text: $newReference, prompt: Text("myimage:dev"))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(apply)

            Text("Both references point at the same image; nothing is copied.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Tag", action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }

    private var trimmed: String {
        newReference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func apply() {
        let target = trimmed
        guard !target.isEmpty else { return }
        Task { await model.images.tag(image.reference, as: target) }
        dismiss()
    }
}
