import DockyardCore
import SwiftUI

/// The tabbed detail pane for one container.
///
/// Logs, Stats and Terminal are stubs here; T07, T08 and T14 fill them in. They
/// exist now so the frame, the header and the tab state are settled once.
struct ContainerDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .overview
    @Binding var deletionTarget: ContainerItem?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        case stats = "Stats"
        case terminal = "Terminal"
        case inspect = "Inspect"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: "info.circle"
            case .logs: "text.alignleft"
            case .stats: "chart.line.uptrend.xyaxis"
            case .terminal: "terminal"
            case .inspect: "curlybraces"
            }
        }
    }

    private var actions: ContainerActions { ContainerActions(model: model) }
    private var store: ContainerDetailStore { model.containerDetail }

    var body: some View {
        Group {
            if let detail = store.detail {
                content(detail)
            } else if store.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyListView(
                    symbol: "sidebar.right",
                    title: "No container selected",
                    message: store.lastError?.errorDescription
                )
            }
        }
        .task(id: tab) {
            if tab == .inspect { await store.loadInspectJSON() }
        }
    }

    private func content(_ detail: ContainerDetail) -> some View {
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
                ContainerOverviewView(detail: detail)
            case .logs:
                LogsView(containerID: detail.id)
            case .inspect:
                InspectView(json: store.inspectJSON, title: detail.id)
            case .stats, .terminal:
                EmptyListView(
                    symbol: tab.symbol,
                    title: tab.rawValue,
                    message: comingSoon
                )
            }
        }
    }

    private var comingSoon: String {
        switch tab {
        case .stats: "CPU and memory charts arrive in T08."
        case .terminal: "An interactive shell arrives in T14."
        default: ""
        }
    }

    private func header(_ detail: ContainerDetail) -> some View {
        let item = model.containers.item(id: detail.id)

        return HStack(alignment: .top, spacing: 12) {
            ContainerStatusBadge(
                status: detail.status,
                isBusy: model.containers.pendingAction(for: detail.id) != nil
            )
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(detail.id)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(detail.image)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(model.containers.pendingAction(for: detail.id)?.label ?? detail.status.rawValue.capitalized)
                    if let started = detail.startedAt, detail.status == .running {
                        Text("·")
                        Text("up \(started, format: .relative(presentation: .numeric, unitsStyle: .narrow))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let item {
                HStack(spacing: 8) {
                    if actions.canStart(item) {
                        Button("Start", systemImage: "play.fill") { actions.start(item) }
                            .disabled(actions.isBusy(item))
                    }
                    if actions.canStop(item) {
                        Button("Stop", systemImage: "stop.fill") { actions.stop(item) }
                            .disabled(actions.isBusy(item))
                    }
                    Button("Delete", systemImage: "trash") { deletionTarget = item }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(14)
    }
}
