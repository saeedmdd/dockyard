import DockyardCore
import SwiftUI
import UniformTypeIdentifiers

/// Builds an image from a folder containing a Dockerfile.
struct BuildSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var spec = BuildSpec(contextDirectory: FileManager.default.homeDirectoryForCurrentUser)
    @State private var hasChosenFolder = false
    @State private var isTargeted = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Build an image")
                .font(.title3.weight(.semibold))
                .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    folderPicker
                    dockerfileField
                    tagField
                    DisclosureGroup("Options", isExpanded: $showAdvanced) {
                        advanced
                            .padding(.top, 8)
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 540, height: 540)
    }

    // MARK: - Fields

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Build folder")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(hasChosenFolder ? .primary : .tertiary)
                Text(hasChosenFolder ? spec.contextDirectory.path : "Choose a folder, or drop one here")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(hasChosenFolder ? .primary : .secondary)
                Spacer()
                Button("Choose…", action: chooseFolder)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isTargeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
            )
            // Dropping a project folder is the fastest way in, and the one a
            // user is most likely to try first.
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                loadDroppedFolder(from: providers)
            }
        }
    }

    private var dockerfileField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dockerfile")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Dockerfile", text: $spec.dockerfile)
                .textFieldStyle(.roundedBorder)
            if hasChosenFolder, let resolved = spec.resolvedDockerfileURL,
                !FileManager.default.fileExists(atPath: resolved.path)
            {
                Label("Not found in that folder", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text("Image name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("required")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TextField("myapp:dev", text: $spec.tag)
                .textFieldStyle(.roundedBorder)
            Text("Without a name the runtime files the image under a generated ID.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyValueListEditor(
                title: "build arg",
                keyPlaceholder: "VERSION",
                valuePlaceholder: "1.2",
                pairs: $spec.buildArguments
            )
            KeyValueListEditor(title: "label", pairs: $spec.labels)
            LabeledField("Target stage") {
                TextField("Final stage by default", text: $spec.target)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Platform") {
                TextField("Defaults to this Mac", text: $spec.platform)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Ignore the cache", isOn: $spec.noCache)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let problem = spec.validationProblems.first, hasChosenFolder {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button("Build") {
                model.builds.start(spec)
                model.selectedSection = .images
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChosenFolder || !spec.isBuildable)
        }
        .padding(16)
    }

    // MARK: - Folder handling

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder to build from"
        if panel.runModal() == .OK, let url = panel.url {
            apply(folder: url)
        }
    }

    private func loadDroppedFolder(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
            Task { @MainActor in
                // Dropping the Dockerfile itself is an easy mistake, and the
                // folder that contains it is obviously what was meant.
                apply(folder: isDirectory.boolValue ? url : url.deletingLastPathComponent())
            }
        }
        return true
    }

    private func apply(folder: URL) {
        spec.contextDirectory = folder
        hasChosenFolder = true
        if let detected = BuildSpec.detectDockerfile(in: folder) {
            spec.dockerfile = detected
        }
        if spec.trimmedTag.isEmpty {
            // The folder name is almost always what the image should be called.
            let suggestion = folder.lastPathComponent.lowercased()
                .replacingOccurrences(of: " ", with: "-")
            if BuildSpec.isValidTag(suggestion) {
                spec.tag = "\(suggestion):latest"
            }
        }
    }
}

/// A build's progress and output, shown above the images list.
struct BuildJobRow: View {
    let job: BuildJob
    let dismiss: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.spec.trimmedTag)
                        .font(.callout.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)

                Button(isExpanded ? "Hide Output" : "Show Output") {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)

                if job.isFinished {
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.link)
                } else {
                    Button("Cancel") { job.cancel() }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if isExpanded {
                BuildOutputView(lines: job.output.lines)
                    .frame(height: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private var background: Color {
        switch job.state {
        case .failed: .orange.opacity(0.1)
        case .succeeded: .green.opacity(0.08)
        default: .clear
        }
    }

    private var detail: String {
        switch job.state {
        case .running:
            job.lastLine ?? "Starting the builder…"
        case .succeeded:
            "Built in \(Int(job.duration))s"
        case .failed(let code):
            "Failed with exit code \(code) — \(job.lastLine ?? "see output")"
        case .cancelled:
            "Cancelled"
        }
    }
}

/// Build output, in the same `NSTextView` the container logs use.
struct BuildOutputView: NSViewRepresentable {
    let lines: [LogLine]

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(lines)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var textView: NSTextView?
        private var rendered = 0

        func apply(_ lines: [LogLine]) {
            guard let textView, let storage = textView.textStorage else { return }
            if lines.count < rendered {
                storage.setAttributedString(NSAttributedString())
                rendered = 0
            }
            guard lines.count > rendered else { return }
            let text = lines[rendered...].map(\.text).joined(separator: "\n") + "\n"
            storage.append(
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.textColor,
                    ]
                )
            )
            rendered = lines.count
            textView.scrollRangeToVisible(NSRange(location: max(0, storage.length - 1), length: 1))
        }
    }
}
