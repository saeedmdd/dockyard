import DockyardCore
import SwiftUI

struct ContainersListView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ContainerItem.id)]

    var body: some View {
        @Bindable var model = model

        Group {
            if model.containers.items.isEmpty {
                EmptyListView(
                    symbol: "shippingbox",
                    title: model.containers.isLoadingInitially ? "Loading…" : "No containers yet",
                    message: model.containers.isLoadingInitially
                        ? nil
                        : "Run an image to create one. Pulling and running arrive in T09 and T11."
                )
            } else {
                // Sorted at the view rather than in the store, so each poll's
                // fresh data keeps whatever order the user picked.
                Table(
                    model.containers.items.sorted(using: sortOrder),
                    selection: $model.selectedContainerID,
                    sortOrder: $sortOrder
                ) {
                    TableColumn("") { container in
                        ContainerStatusBadge(status: container.status)
                    }
                    .width(18)

                    TableColumn("Name", value: \.id) { container in
                        Text(container.id)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 120, ideal: 200)

                    TableColumn("Image", value: \.image) { container in
                        Text(container.image)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 140, ideal: 240)

                    TableColumn("State") { container in
                        Text(container.status.rawValue.capitalized)
                            .foregroundStyle(container.status == .running ? .primary : .secondary)
                    }
                    .width(70)

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

                    TableColumn("Started") { container in
                        RelativeDateCell(date: container.startedAt)
                    }
                    .width(90)
                }
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let total = model.containers.items.count
        let running = model.containers.running.count
        return total == 0 ? "" : "\(running) running of \(total)"
    }
}

/// Coloured dot for a container's state.
struct ContainerStatusBadge: View {
    let status: ContainerStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(status.rawValue)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
