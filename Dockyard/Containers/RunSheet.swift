import DockyardCore
import SwiftUI

/// The full `container run` form.
///
/// Everything beyond the basics sits in collapsed sections: most runs need an
/// image and maybe a port, and burying that under thirty fields would make the
/// common case worse to serve the rare one.
struct RunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var spec: RunSpec
    @State private var expanded: Set<Section> = []
    @FocusState private var isImageFocused: Bool

    init(image: ImageItem? = nil) {
        var spec = RunSpec()
        // Pre-filled when launched from an image, which is the path that turns
        // a pulled image into something running.
        spec.image = image?.displayReference ?? ""
        _spec = State(initialValue: spec)
    }

    enum Section: String, CaseIterable, Identifiable {
        case ports = "Ports"
        case environment = "Environment"
        case storage = "Storage"
        case resources = "Resources"
        case network = "Network"
        case advanced = "Advanced"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .ports: "point.3.connected.trianglepath.dotted"
            case .environment: "list.bullet.rectangle"
            case .storage: "externaldrive"
            case .resources: "gauge.with.dots.needle.33percent"
            case .network: "network"
            case .advanced: "gearshape.2"
            }
        }
    }

    private var store: RunStore { model.run }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .onAppear { isImageFocused = spec.image.isEmpty }
        .onDisappear { store.reset() }
    }

    private var header: some View {
        HStack {
            Text("Run a container")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(16)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                basics
                ForEach(Section.allCases) { section in
                    disclosure(section)
                }
            }
            .padding(16)
        }
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("Image", required: true) {
                TextField("alpine:3.20", text: $spec.image)
                    .textFieldStyle(.roundedBorder)
                    .focused($isImageFocused)
            }
            LabeledField("Name") {
                TextField("Optional — one is generated", text: $spec.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Command") {
                TextField("Overrides the image's default", text: $spec.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Toggle("Start immediately", isOn: $spec.startImmediately)
            Toggle("Delete when it stops", isOn: $spec.removeWhenStopped)
        }
    }

    @ViewBuilder
    private func disclosure(_ section: Section) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(section) },
                set: { isOpen in
                    if isOpen { expanded.insert(section) } else { expanded.remove(section) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 10) {
                switch section {
                case .ports: portsSection
                case .environment: environmentSection
                case .storage: storageSection
                case .resources: resourcesSection
                case .network: networkSection
                case .advanced: advancedSection
                }
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Label(section.rawValue, systemImage: section.symbol)
                if let summary = summary(for: section) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A hint of what is set inside a collapsed section, so nothing configured
    /// is invisible.
    private func summary(for section: Section) -> String? {
        switch section {
        case .ports:
            spec.publishedPorts.isEmpty ? nil : "\(spec.publishedPorts.count)"
        case .environment:
            spec.environment.isEmpty ? nil : "\(spec.environment.count)"
        case .storage:
            (spec.volumes.count + spec.mounts.count + spec.tmpfs.count) == 0
                ? nil : "\(spec.volumes.count + spec.mounts.count + spec.tmpfs.count)"
        case .resources:
            [spec.cpus.isEmpty ? nil : "\(spec.cpus) CPU", spec.memory.isEmpty ? nil : spec.memory]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case .network:
            spec.networks.isEmpty ? nil : spec.networks.joined(separator: ", ")
        case .advanced:
            nil
        }
    }

    private var portsSection: some View {
        StringListEditor(
            title: "port",
            placeholder: "8080:80",
            help: "host:container, optionally /tcp or /udp",
            values: $spec.publishedPorts
        )
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyValueListEditor(title: "variable", pairs: $spec.environment)
            StringListEditor(
                title: "env file",
                placeholder: "/path/to/.env",
                values: $spec.environmentFiles
            )
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StringListEditor(
                title: "volume",
                placeholder: "/Users/me/data:/data",
                help: "host:container, add :ro for read-only",
                values: $spec.volumes
            )
            StringListEditor(
                title: "mount",
                placeholder: "type=volume,source=data,target=/data",
                values: $spec.mounts
            )
            StringListEditor(
                title: "tmpfs",
                placeholder: "/run:64m",
                values: $spec.tmpfs
            )
            Toggle("Read-only root filesystem", isOn: $spec.readOnlyRootFilesystem)
        }
    }

    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("CPUs") {
                TextField("Default", text: $spec.cpus)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            LabeledField("Memory") {
                TextField("512m, 2g…", text: $spec.memory)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            LabeledField("Shared memory") {
                TextField("64m", text: $spec.shmSize)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StringListEditor(title: "network", placeholder: "default", values: $spec.networks)
            StringListEditor(title: "nameserver", placeholder: "1.1.1.1", values: $spec.dnsNameservers)
            LabeledField("DNS domain") {
                TextField("Optional", text: $spec.dnsDomain)
                    .textFieldStyle(.roundedBorder)
            }
            StringListEditor(title: "search domain", placeholder: "svc.local", values: $spec.dnsSearchDomains)
            Toggle("Disable DNS", isOn: $spec.disableDNS)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("Entrypoint") {
                TextField("Overrides the image's entrypoint", text: $spec.entrypoint)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Working directory") {
                TextField("/", text: $spec.workingDirectory)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("User") {
                TextField("root or 1000:1000", text: $spec.user)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Platform") {
                TextField("Defaults to this Mac", text: $spec.platform)
                    .textFieldStyle(.roundedBorder)
            }
            KeyValueListEditor(title: "label", pairs: $spec.labels)
            StringListEditor(title: "added capability", placeholder: "NET_ADMIN", values: $spec.addedCapabilities)
            StringListEditor(title: "dropped capability", placeholder: "CHOWN", values: $spec.droppedCapabilities)
            Toggle("Allocate a terminal", isOn: $spec.allocateTerminal)
            Toggle("Forward SSH agent", isOn: $spec.forwardSSHAgent)
            Toggle("Enable Rosetta", isOn: $spec.enableRosetta)
            Toggle("Nested virtualization", isOn: $spec.enableVirtualization)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = store.progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text(progressDetail(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if case .failed(let error) = store.state {
                Label(error.errorDescription ?? "Could not create the container", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else if let problem = spec.validationProblems.first {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    if store.isWorking { store.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(spec.startImmediately ? "Run" : "Create") {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!spec.isRunnable || store.isWorking)
            }
        }
        .padding(16)
    }

    private func progressDetail(_ progress: PullProgress) -> String {
        let phase = progress.description.isEmpty ? "Preparing…" : progress.description
        let parts = [progress.bytesSummary, progress.itemsSummary].compactMap { $0 }
        return parts.isEmpty ? phase : "\(phase) · \(parts.joined(separator: " · "))"
    }

    private func run() {
        Task {
            if let id = await store.create(spec: spec, then: spec.startImmediately) {
                model.selectedSection = .containers
                model.selectedContainerID = id
                dismiss()
            }
        }
    }
}

/// A label above a field, with an optional required marker.
struct LabeledField<Content: View>: View {
    let title: String
    var required = false
    @ViewBuilder let content: Content

    init(_ title: String, required: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.required = required
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if required {
                    Text("required")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}
