import DockyardCore
import SwiftUI

/// An editable list of single strings, e.g. port mappings or networks.
struct StringListEditor: View {
    let title: String
    let placeholder: String
    var help: String?
    @Binding var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(placeholder, text: binding(at: index))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        values.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(title) entry")
                }
            }
            HStack(spacing: 6) {
                Button {
                    values.append("")
                } label: {
                    Label("Add \(title)", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Indexes can go stale between a removal and the next render, so reads are
    /// guarded rather than trusting the index.
    private func binding(at index: Int) -> Binding<String> {
        Binding(
            get: { values.indices.contains(index) ? values[index] : "" },
            set: { if values.indices.contains(index) { values[index] = $0 } }
        )
    }
}

/// An editable list of key/value pairs, e.g. environment variables or labels.
struct KeyValueListEditor: View {
    let title: String
    var keyPlaceholder = "KEY"
    var valuePlaceholder = "value"
    var help: String?
    @Binding var pairs: [RunSpec.KeyValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pairs) { pair in
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: keyBinding(for: pair))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)
                    Text("=").foregroundStyle(.secondary)
                    TextField(valuePlaceholder, text: valueBinding(for: pair))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        pairs.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(title) entry")
                }
            }
            HStack(spacing: 6) {
                Button {
                    pairs.append(RunSpec.KeyValue())
                } label: {
                    Label("Add \(title)", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keyBinding(for pair: RunSpec.KeyValue) -> Binding<String> {
        Binding(
            get: { pairs.first { $0.id == pair.id }?.key ?? "" },
            set: { newValue in
                guard let index = pairs.firstIndex(where: { $0.id == pair.id }) else { return }
                pairs[index].key = newValue
            }
        )
    }

    private func valueBinding(for pair: RunSpec.KeyValue) -> Binding<String> {
        Binding(
            get: { pairs.first { $0.id == pair.id }?.value ?? "" },
            set: { newValue in
                guard let index = pairs.firstIndex(where: { $0.id == pair.id }) else { return }
                pairs[index].value = newValue
            }
        )
    }
}
