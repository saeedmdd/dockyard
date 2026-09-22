import DockyardCore
import SwiftUI

struct ContainerOverviewView: View {
    let detail: ContainerDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                process
                if !detail.ports.isEmpty { portsSection }
                if !detail.networks.isEmpty { networksSection }
                if !detail.userVisibleMounts.isEmpty { mountsSection }
                resources
                if !detail.environment.isEmpty { environmentSection }
                if !detail.labels.isEmpty { labelsSection }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var process: some View {
        Section("Process") {
            CopyableRow(label: "Command", value: detail.commandLine, isMonospaced: true)
            LabeledContent("Working directory", value: detail.workingDirectory)
            LabeledContent("User", value: detail.user)
            if detail.hasTerminal {
                LabeledContent("Terminal", value: "Allocated")
            }
        }
    }

    private var portsSection: some View {
        Section("Ports") {
            ForEach(detail.ports) { port in
                LabeledContent {
                    if let url = port.localURL {
                        Link("localhost:\(port.hostPort)", destination: url)
                    } else {
                        Text("\(port.hostAddress):\(port.hostPort)")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("\(port.containerPort)/\(port.networkProtocol) in container")
                }
            }
        }
    }

    private var networksSection: some View {
        Section("Networks") {
            ForEach(detail.networks) { network in
                LabeledContent(network.network) {
                    Text(network.ipv4Address)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Hostname") {
                    Text(network.hostname).foregroundStyle(.secondary)
                }
            }
            if !detail.dnsNameservers.isEmpty {
                LabeledContent("DNS", value: detail.dnsNameservers.joined(separator: ", "))
            }
            if let domain = detail.dnsDomain {
                LabeledContent("Domain", value: domain)
            }
            if !detail.dnsSearchDomains.isEmpty {
                LabeledContent("Search domains", value: detail.dnsSearchDomains.joined(separator: ", "))
            }
        }
    }

    private var mountsSection: some View {
        Section("Mounts") {
            ForEach(detail.userVisibleMounts) { mount in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: mount.kind.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mount.destination)
                            .font(.system(.callout, design: .monospaced))
                        HStack(spacing: 6) {
                            Text(mount.volumeName ?? mount.source)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if mount.isReadOnly {
                                Text("read-only")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            // A host folder that has gone missing stops the
                            // container from starting, so it is worth flagging
                            // before the user wonders why Start failed.
                            if mount.requiresHostPath, !FileManager.default.fileExists(atPath: mount.source) {
                                Label("missing", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("This folder no longer exists; the container will not start.")
                            }
                        }
                        .font(.caption)
                    }
                    Spacer()
                    Text(mount.kind.title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var resources: some View {
        Section("Resources") {
            LabeledContent("CPUs", value: "\(detail.cpus)")
            LabeledContent("Memory", value: detail.memoryInBytes.formatted(.byteCount(style: .memory)))
            LabeledContent("Platform", value: "\(detail.os)/\(detail.architecture)")
            LabeledContent("Runtime", value: detail.runtimeHandler)
            if detail.isRosettaEnabled {
                LabeledContent("Rosetta", value: "Enabled")
            }
            if detail.isVirtualizationEnabled {
                LabeledContent("Nested virtualization", value: "Enabled")
            }
            if detail.isReadOnlyRootFilesystem {
                LabeledContent("Root filesystem", value: "Read-only")
            }
            LabeledContent("Created") {
                Text(detail.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var environmentSection: some View {
        Section("Environment") {
            ForEach(detail.environment.keys.sorted(), id: \.self) { key in
                CopyableRow(
                    label: key,
                    value: detail.environment[key] ?? "",
                    isMonospaced: true
                )
            }
        }
    }

    private var labelsSection: some View {
        Section("Labels") {
            ForEach(detail.labels.keys.sorted(), id: \.self) { key in
                LabeledContent(key, value: detail.labels[key] ?? "")
            }
        }
    }

    /// A titled group of rows.
    private func Section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// A label/value row whose value can be copied — useful for long commands and
/// environment values that would otherwise be painful to retype.
struct CopyableRow: View {
    let label: String
    let value: String
    var isMonospaced = false

    @State private var didCopy = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value)
                    .font(isMonospaced ? .system(.callout, design: .monospaced) : .callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(didCopy ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityLabel("Copy \(label)")
            }
        } label: {
            Text(label)
        }
    }
}
