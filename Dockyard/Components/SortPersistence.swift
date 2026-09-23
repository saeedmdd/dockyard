import DockyardCore
import SwiftUI

/// Remembers how a table was sorted, across launches.
///
/// `KeyPathComparator` cannot be written to `UserDefaults`, so what is stored
/// is a name the view chooses per column plus the direction. The name is also
/// what makes the stored value survive reordering or renaming a column: an
/// index would silently start sorting by the wrong thing.
struct PersistentSort<Item>: ViewModifier {
    @Environment(AppModel.self) private var model

    @Binding var sortOrder: [KeyPathComparator<Item>]
    let table: AppSettings.SortedTable
    /// Every column the user can sort by, keyed by a stable name.
    let columns: [String: KeyPathComparator<Item>]

    func body(content: Content) -> some View {
        content
            .onAppear(perform: restore)
            .onChange(of: sortOrder) { _, new in save(new) }
    }

    private func restore() {
        guard let stored = model.settings.sort(for: table),
            var comparator = columns[stored.column]
        else { return }
        comparator.order = stored.isAscending ? .forward : .reverse
        sortOrder = [comparator]
    }

    private func save(_ order: [KeyPathComparator<Item>]) {
        guard let current = order.first,
            let name = columns.first(where: { $0.value.keyPath == current.keyPath })?.key
        else {
            // A column with no name here is one this view forgot to list;
            // forgetting the saved sort is better than storing something that
            // cannot be restored.
            model.settings.setSort(nil, for: table)
            return
        }
        model.settings.setSort(
            AppSettings.SortSelection(column: name, isAscending: current.order == .forward),
            for: table
        )
    }
}

extension View {
    func persistentSort<Item>(
        _ sortOrder: Binding<[KeyPathComparator<Item>]>,
        table: AppSettings.SortedTable,
        columns: [String: KeyPathComparator<Item>]
    ) -> some View {
        modifier(PersistentSort(sortOrder: sortOrder, table: table, columns: columns))
    }
}
