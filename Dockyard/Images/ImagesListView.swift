import DockyardCore
import SwiftUI
import UniformTypeIdentifiers

struct ImagesListView: View {
    @Environment(AppModel.self) private var model
    @State private var isSearchPresented = false
    @State private var sortOrder = [KeyPathComparator(\ImageItem.displayReference)]
    @State private var isShowingPullSheet = false
    @State private var tagTarget: ImageItem?
    @State private var deletionTarget: ImageItem?
    @State private var isShowingBuildSheet = false
    @State private var handledBuildRequest = 0
    @State private var handledPullRequest = 0
    @State private var isShowingRegistrySheet = false
    @State private var pushTarget: ImageItem?

    var body: some View {
        @Bindable var model = model
        // `images` is a `let` on the model, so the toggle binds through the
        // store itself rather than through the model.
        @Bindable var images = model.images

        VStack(spacing: 0) {
            if let error = model.images.actionError {
                ActionErrorBanner(error: error) { model.images.clearActionError() }
            }
            if let note = model.registry.statusNote {
                StatusNoteBanner(text: note) { model.registry.clearStatusNote() }
            }
            ForEach(model.registry.pushes) { job in
                PullProgressRow(job: job) { model.registry.dismiss(job) }
            }
            ForEach(model.builds.jobs) { job in
                BuildJobRow(job: job) { model.builds.dismiss(job) }
            }
            ForEach(model.images.pulls) { job in
                PullProgressRow(job: job) { model.images.dismiss(job) }
            }

            if model.images.visibleItems.isEmpty {
                EmptyListView(
                    symbol: "square.stack.3d.up",
                    title: model.images.isLoadingInitially ? "Loading…" : "No images yet",
                    message: model.images.isLoadingInitially ? nil : emptyMessage,
                    actionTitle: model.images.isLoadingInitially ? nil : "Pull an Image…",
                    action: model.images.isLoadingInitially ? nil : { isShowingPullSheet = true }
                )
                .frame(maxHeight: .infinity)
            } else if visibleImages.isEmpty {
                NoSearchResultsView(query: model.searchQuery, noun: "images") {
                    model.searchQuery = ""
                }
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    imagesTable
                        .frame(minWidth: 360, idealWidth: 560)
                    if model.selectedImageID != nil {
                        ImageDetailView(tagTarget: $tagTarget, pushTarget: $pushTarget, deletionTarget: $deletionTarget)
                            .frame(minWidth: 340, idealWidth: 420)
                    }
                }
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle(subtitle)
        .searchable(
            text: $model.searchQuery,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Repository, tag, digest"
        )
        // `isPresented` is the only way to put the cursor in the field from a
        // menu command; there is no focus binding for a search field.
        .onChange(of: model.findRequest) { isSearchPresented = true }
        .persistentSort(
            $sortOrder,
            table: .images,
            columns: [
                "repository": KeyPathComparator(\ImageItem.repository),
                "tag": KeyPathComparator(\ImageItem.sortableTag),
                "reference": KeyPathComparator(\ImageItem.displayReference),
            ]
        )
        .sheet(item: $tagTarget) { image in
            TagImageSheet(image: image)
        }
        .deleteImageConfirmation(target: $deletionTarget)
        .onChange(of: model.deleteSelectionRequest) {
            if let id = model.selectedImageID,
                let image = model.images.items.first(where: { $0.id == id })
            {
                deletionTarget = image
            }
        }
        .toolbar {
            Button("Registries", systemImage: "key") {
                isShowingRegistrySheet = true
            }
            .help("Sign in to a registry")
                .accessibilityLabel("Registries")

            Menu("Archive", systemImage: "archivebox") {
                Button("Save Selected Image…") { saveSelected() }
                    .disabled(model.selectedImageID == nil)
                Button("Load from Archive…") { loadArchive() }
            }
            .help("Save images to a tar archive, or load them back")
                .accessibilityLabel("Save or load a tar archive")

            Button("Build Image", systemImage: "hammer") {
                isShowingBuildSheet = true
            }
            .help("Build an image from a Dockerfile")
                .accessibilityLabel("Build an image")

            Button("Pull Image", systemImage: "arrow.down.circle") {
                isShowingPullSheet = true
            }
            .help("Pull an image from a registry")
                .accessibilityLabel("Pull an image")

            Toggle("Show runtime images", isOn: $images.showsInfrastructure)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show the builder and VM init images the runtime manages itself")
        }
        .sheet(isPresented: $isShowingPullSheet) {
            PullSheet()
        }
        .sheet(isPresented: $isShowingBuildSheet) {
            BuildSheet()
        }
        .sheet(isPresented: $isShowingRegistrySheet) {
            RegistrySheet()
        }
        .sheet(item: $pushTarget) { image in
            PushSheet(image: image)
        }
        .onAppear(perform: openRequestedSheet)
        .onChange(of: model.buildSheetRequest) { openRequestedSheet() }
        .onChange(of: model.pullSheetRequest) { openRequestedSheet() }
    }

    /// Opens whichever sheet was asked for since this screen last looked.
    ///
    /// Counters, not flags: the request usually arrives before this view
    /// exists, so it has to be readable after the fact rather than only as a
    /// change. `handled*` is what stops the sheet reopening on every appear.
    private func openRequestedSheet() {
        if model.buildSheetRequest != handledBuildRequest {
            handledBuildRequest = model.buildSheetRequest
            isShowingBuildSheet = true
        }
        if model.pullSheetRequest != handledPullRequest {
            handledPullRequest = model.pullSheetRequest
            isShowingPullSheet = true
        }
    }

    private var imagesTable: some View {
        @Bindable var model = model

        return Table(
                    visibleImages.sorted(using: sortOrder),
                    selection: $model.selectedImageID,
                    sortOrder: $sortOrder
                ) {
                    TableColumn("Repository", value: \.repository) { image in
                        Text(image.repository)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 160, ideal: 280)

                    TableColumn("Tag", value: \.sortableTag) { image in
                        Text(image.tag ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 110)

                    TableColumn("Digest") { image in
                        Text(image.shortDigest)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .width(120)

                    TableColumn("Kind") { image in
                        if image.isInfrastructure {
                            Text("runtime")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help("Used internally by the container runtime")
                        } else {
                            Text("")
                        }
                    }
                    .width(70)
                }
    }

    /// Writes the selected image to a tar archive.
    private func saveSelected() {
        guard let id = model.selectedImageID,
            let image = model.images.items.first(where: { $0.reference == id })
        else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.nameFieldStringValue = "\(image.repository.replacingOccurrences(of: "/", with: "-")).tar"
        panel.message = "Save \(image.displayReference) as an archive"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.registry.save(references: [image.reference], to: url) }
    }

    private func loadArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.message = "Choose an image archive to load"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            _ = await model.registry.load(from: url)
            await model.images.refresh()
        }
    }

    private var emptyMessage: String {
        let hidden = model.images.infrastructureCount
        if hidden > 0 && !model.images.showsInfrastructure {
            return "\(hidden) runtime image\(hidden == 1 ? "" : "s") hidden. Pull an image to get started."
        }
        return "Pull an image to get started."
    }

    /// The rows the search leaves, out of the ones the infrastructure filter
    /// already allows.
    private var visibleImages: [ImageItem] {
        model.images.visibleItems.matching(model.searchQuery)
    }

    private var subtitle: String {
        let visible = model.images.visibleItems.count
        guard visible > 0 else { return "" }
        let shown = visibleImages.count
        if shown != visible {
            return "\(shown) of \(visible) shown"
        }
        let hidden = model.images.showsInfrastructure ? 0 : model.images.infrastructureCount
        return hidden > 0 ? "\(visible) shown · \(hidden) runtime hidden" : "\(visible) images"
    }
}
