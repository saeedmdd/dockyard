import DockyardCore
import SwiftUI

struct LogsView: View {
    let containerID: String
    @Environment(AppModel.self) private var model

    @State private var matchIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var store: LogStore { model.logs }

    var body: some View {
        @Bindable var store = model.logs

        VStack(spacing: 0) {
            toolbar
            Divider()

            if let error = store.lastError {
                ActionErrorBanner(error: error) {}
                    .transition(.opacity)
            }

            if store.isLoading && store.buffer.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.buffer.isEmpty {
                EmptyListView(
                    symbol: "text.alignleft",
                    title: "No output yet",
                    message: store.source == .stdio
                        ? "Anything the container writes will appear here as it happens."
                        : "The guest VM has not written a boot log."
                )
            } else {
                LogTextView(
                    store: store,
                    version: store.buffer.totalCount,
                    searchQuery: store.searchQuery,
                    scrollTarget: currentMatch,
                    isFollowing: Binding(
                        get: { store.isFollowing },
                        set: { store.setFollowing($0) }
                    )
                )
            }

            Divider()
            statusBar
        }
        .task(id: containerID) {
            await store.start(containerID: containerID)
        }
        .onDisappear {
            // Releases the file handle and the watch; leaving them open would
            // leak a descriptor for every container the user clicks through.
            store.stop()
        }
    }

    private var toolbar: some View {
        @Bindable var store = model.logs

        return HStack(spacing: 10) {
            Picker("", selection: $store.source) {
                ForEach(LogSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Switch between the container's output and the guest VM's boot log")

            Toggle(isOn: Binding(get: { store.isFollowing }, set: { store.setFollowing($0) })) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Scroll automatically as new output arrives")

            searchField

            Spacer()

            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.buffer.joined(), forType: .string)
            }
            .help("Copy all visible output")
            .accessibilityLabel("Copy all output")

            Button("Clear", systemImage: "trash") {
                store.clear()
            }
            .help("Clear the view. The log file itself is not touched.")
            .accessibilityLabel("Clear log view")
        }
        .padding(8)
    }

    private var searchField: some View {
        @Bindable var store = model.logs

        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .frame(width: 140)
                .focused($isSearchFocused)
                // ⌘F belongs on a menu command, not on this field: a shortcut
                // attached here only works once the field already has focus.
                .onChange(of: model.logSearchFocusRequest) { isSearchFocused = true }
                .onSubmit { advanceMatch(by: 1) }
                .onChange(of: store.searchQuery) { matchIndex = 0 }

            if !store.searchQuery.isEmpty {
                let matches = store.matchIndices
                Text(matches.isEmpty ? "none" : "\(min(matchIndex + 1, matches.count))/\(matches.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    advanceMatch(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(matches.isEmpty)
                .accessibilityLabel("Previous match")
                Button {
                    advanceMatch(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(matches.isEmpty)
                .accessibilityLabel("Next match")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("\(store.buffer.count.formatted()) lines")
            if store.buffer.droppedCount > 0 {
                Text("· \(store.buffer.droppedCount.formatted()) older lines dropped")
                    .help("The view keeps the most recent \(LogBuffer.defaultCapacity.formatted()) lines")
            }
            if store.wasTruncated {
                Label("log restarted", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.orange)
                    .help("The container restarted and the runtime began a new log")
            }
            Spacer()
            if !store.isFollowing {
                Text("paused")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// The buffer index the view should scroll to, if searching.
    private var currentMatch: Int? {
        let matches = store.matchIndices
        guard !matches.isEmpty else { return nil }
        return matches[min(matchIndex, matches.count - 1)]
    }

    private func advanceMatch(by delta: Int) {
        let count = store.matchIndices.count
        guard count > 0 else { return }
        matchIndex = (matchIndex + delta + count) % count
        // Jumping to a match means leaving the bottom; following would yank
        // the view straight back.
        store.setFollowing(false)
    }
}
