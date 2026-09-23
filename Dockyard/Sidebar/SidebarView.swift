import DockyardCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedSection) {
            Section("Workloads") {
                row(.containers, badge: model.containers.items.count)
                row(.images, badge: model.images.visibleItems.count)
            }
            Section("Infrastructure") {
                row(.volumes, badge: model.volumes.items.count)
                row(.networks, badge: nil)
            }
            Section {
                row(.system, badge: nil)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        .safeAreaInset(edge: .bottom) {
            daemonFooter
        }
    }

    private func row(_ section: SidebarSection, badge: Int?) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge ?? 0)
            .tag(section)
    }

    private var daemonFooter: some View {
        HStack(spacing: 7) {
            StatusDot(status: model.system.status)
            Text(model.system.status.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
