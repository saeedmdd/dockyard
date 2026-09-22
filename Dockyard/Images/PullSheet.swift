import DockyardCore
import SwiftUI

/// Sheet for pulling an image by reference.
struct PullSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var reference = ""
    @State private var platform = PlatformChoice.host
    @FocusState private var isReferenceFocused: Bool

    /// Recent references, so pulling the same image twice is not retyping.
    @AppStorage("recentPullReferences") private var recentJSON = "[]"

    enum PlatformChoice: String, CaseIterable, Identifiable {
        case host
        case arm64
        case amd64

        var id: String { rawValue }

        var title: String {
            switch self {
            case .host: "This Mac (arm64)"
            case .arm64: "linux/arm64"
            case .amd64: "linux/amd64"
            }
        }

        /// `nil` lets the runtime choose, which is what the CLI does by default.
        var value: String? {
            switch self {
            case .host: nil
            case .arm64: "linux/arm64"
            case .amd64: "linux/amd64"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pull an image")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField("Image reference", text: $reference, prompt: Text("alpine:3.20"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isReferenceFocused)
                    .onSubmit(startPull)
                Text("A short name is expanded the way the CLI expands it — `alpine` becomes `docker.io/library/alpine:latest`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !recentReferences.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recentReferences, id: \.self) { recent in
                                Button(recent) { reference = recent }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Picker("Platform", selection: $platform) {
                ForEach(PlatformChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pull", action: startPull)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedReference.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isReferenceFocused = true }
    }

    private var trimmedReference: String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recentReferences: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentJSON.utf8))) ?? []
    }

    private func startPull() {
        let reference = trimmedReference
        guard !reference.isEmpty else { return }
        model.images.pull(reference: reference, platform: platform.value)
        remember(reference)
        dismiss()
    }

    private func remember(_ reference: String) {
        var recents = recentReferences.filter { $0 != reference }
        recents.insert(reference, at: 0)
        recents = Array(recents.prefix(6))
        if let data = try? JSONEncoder().encode(recents) {
            recentJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

/// One in-flight or just-finished pull, shown above the images list.
struct PullProgressRow: View {
    let job: PullJob
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                Text(job.requestedReference)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if case .running = job.state {
                    ProgressView(value: job.progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if case .running = job.state {
                Button("Cancel") { job.cancel() }
                    .buttonStyle(.link)
            } else {
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .running:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.blue)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
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
            let phase = job.progress.description.isEmpty ? "Starting…" : job.progress.description
            // Whichever measure the runtime is actually reporting; it gives
            // bytes while fetching and item counts while unpacking.
            let parts = [job.progress.bytesSummary, job.progress.itemsSummary].compactMap { $0 }
            return parts.isEmpty ? phase : "\(phase) · \(parts.joined(separator: " · "))"
        case .succeeded:
            return "Pulled and unpacked"
        case .cancelled:
            return "Cancelled"
        case .failed(let error):
            return error.errorDescription ?? "Pull failed"
        }
    }
}
