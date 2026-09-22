import DockyardCore
import SwiftUI

/// Placeholder shell. T04 replaces this with the sidebar + list views.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Dockyard \(DockyardCore.version)")
                .font(.title2)
            Text("Linked against container \(DockyardCore.linkedContainerVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
