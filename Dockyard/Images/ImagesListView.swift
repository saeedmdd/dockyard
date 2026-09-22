import DockyardCore
import SwiftUI

struct ImagesListView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ImageItem.displayReference)]
    @State private var isShowingPullSheet = false
    @State private var tagTarget: ImageItem?
    @State private var deletionTarget: ImageItem?
    @State private var isShowingBuildSheet = false

    var body: some View {
        @Bindable var model = model
        // `images` is a `let` on the model, so the toggle binds through the
        // store itself rather than through the model.
        @Bindable var images = model.images

        VStack(spacing: 0) {
            if let error = model.images.actionError {
                ActionErrorBanner(error: error) { model.images.clearActionError() }
            }
            if let note = model.statusNote {
                StatusNoteBanner(text: note) { model.dismissStatusNote() }
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
                    message: model.images.isLoadingInitially ? nil : emptyMessage
                )
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    imagesTable
                        .frame(minWidth: 360, idealWidth: 560)
                    if model.selectedImageID != nil {
                        ImageDetailView(tagTarget: $tagTarget, deletionTarget: $deletionTarget)
                            .frame(minWidth: 340, idealWidth: 420)
                    }
                }
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle(subtitle)
        .sheet(item: $tagTarget) { image in
            TagImageSheet(image: image)
        }
        .deleteImageConfirmation(target: $deletionTarget)
        .toolbar {
            Button("Build Image", systemImage: "hammer") {
                isShowingBuildSheet = true
            }
            .help("Build an image from a Dockerfile")

            Button("Pull Image", systemImage: "arrow.down.circle") {
                isShowingPullSheet = true
            }
            .help("Pull an image from a registry")

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
        .onChange(of: model.isBuildSheetRequested) { _, requested in
            if requested {
                isShowingBuildSheet = true
                model.isBuildSheetRequested = false
            }
        }
        .onChange(of: model.isPullSheetRequested) { _, requested in
            if requested {
                isShowingPullSheet = true
                model.isPullSheetRequested = false
            }
        }
    }

    private var imagesTable: some View {
        @Bindable var model = model

        return Table(
                    model.images.visibleItems.sorted(using: sortOrder),
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

                    TableColumn("Tag") { image in
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

    private var emptyMessage: String {
        let hidden = model.images.infrastructureCount
        if hidden > 0 && !model.images.showsInfrastructure {
            return "\(hidden) runtime image\(hidden == 1 ? "" : "s") hidden. Pull an image to get started."
        }
        return "Pull an image to get started."
    }

    private var subtitle: String {
        let visible = model.images.visibleItems.count
        guard visible > 0 else { return "" }
        let hidden = model.images.showsInfrastructure ? 0 : model.images.infrastructureCount
        return hidden > 0 ? "\(visible) shown · \(hidden) runtime hidden" : "\(visible) images"
    }
}
