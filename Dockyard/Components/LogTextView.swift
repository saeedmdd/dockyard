import AppKit
import DockyardCore
import SwiftUI

/// An `NSTextView` that logs are appended to.
///
/// SwiftUI's own text views are not an option here: a `ForEach` over 100k lines
/// rebuilds its identity map on every append, and a single `Text` re-lays out
/// the entire string. `NSTextStorage` can have text appended to it without
/// touching what is already laid out, which is what makes a chatty container
/// survivable.
struct LogTextView: NSViewRepresentable {
    /// The store is passed by reference and the lines are read from it inside
    /// the coordinator.
    ///
    /// Passing `[LogLine]` as a property instead looks natural and is a trap:
    /// SwiftUI compares a view's properties to decide what changed, so every
    /// update would compare 100,000 elements. Profiling a container logging in
    /// a loop showed the app pinned at ~150% CPU inside SwiftUI's layout and
    /// comparison machinery — not in the text view, and not in the tailer.
    let store: LogStore
    /// Changes whenever a line is added, so SwiftUI's check is one integer.
    let version: Int
    let searchQuery: String
    /// Index into the buffer to scroll to, for search navigation.
    var scrollTarget: Int?
    @Binding var isFollowing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isFollowing: $isFollowing)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = Coordinator.font
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.observeScrolling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(
            lines: store.buffer.lines,
            searchQuery: searchQuery,
            scrollTarget: scrollTarget,
            isFollowing: isFollowing
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject {
        static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        var textView: NSTextView?
        var scrollView: NSScrollView?

        private var isFollowing: Binding<Bool>
        /// Ids already rendered, so only genuinely new lines are appended.
        private var renderedCount = 0
        private var renderedFirstID: Int?
        /// Character length of each rendered line including its newline, so
        /// lines trimmed from the front can be deleted without recomputing.
        private var renderedLengths: [Int] = []
        private var lastSearchQuery = ""
        private var lastScrollTarget: Int?
        /// Set while the code scrolls, so the resulting notification is not
        /// mistaken for the user scrolling away.
        private var isProgrammaticallyScrolling = false

        init(isFollowing: Binding<Bool>) {
            self.isFollowing = isFollowing
        }

        func observeScrolling() {
            guard let clipView = scrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
        }

        /// Scrolling up is how people read logs, and it must not be fought:
        /// leaving the bottom turns following off, returning to it turns it
        /// back on.
        @objc private func boundsChanged() {
            guard !isProgrammaticallyScrolling, let scrollView else { return }
            let atBottom = isScrolledToBottom(scrollView)
            if atBottom != isFollowing.wrappedValue {
                isFollowing.wrappedValue = atBottom
            }
        }

        private func isScrolledToBottom(_ scrollView: NSScrollView, slack: CGFloat = 24) -> Bool {
            let clip = scrollView.contentView
            guard let document = scrollView.documentView else { return true }
            let maxY = max(0, document.bounds.height - clip.bounds.height)
            return clip.bounds.origin.y >= maxY - slack
        }

        func apply(lines: [LogLine], searchQuery: String, scrollTarget: Int?, isFollowing: Bool) {
            guard let textView, let storage = textView.textStorage else { return }

            let firstID = lines.first?.id
            var wasReset = false

            if let firstID, let renderedFirstID, firstID > renderedFirstID, renderedCount > 0 {
                // The buffer trimmed lines off the front. Deleting that many
                // characters is O(dropped); rebuilding the document would be
                // O(everything), on every batch, forever — which is what made
                // a chatty container peg a core.
                let dropped = min(firstID - renderedFirstID, renderedLengths.count)
                let charactersToRemove = renderedLengths[..<dropped].reduce(0, +)
                if charactersToRemove > 0 && charactersToRemove <= storage.length {
                    storage.beginEditing()
                    storage.deleteCharacters(in: NSRange(location: 0, length: charactersToRemove))
                    storage.endEditing()
                }
                renderedLengths.removeFirst(dropped)
                renderedCount -= dropped
            } else if lines.count < renderedCount || (firstID != nil && renderedFirstID != nil && firstID! < renderedFirstID!) {
                // Cleared, or a different container entirely.
                storage.setAttributedString(NSAttributedString())
                renderedLengths.removeAll(keepingCapacity: true)
                renderedCount = 0
                wasReset = true
            }

            if lines.count > renderedCount {
                let newLines = lines[renderedCount...]
                let text = newLines.map(\.text).joined(separator: "\n") + "\n"
                storage.beginEditing()
                storage.append(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            .font: Self.font,
                            .foregroundColor: NSColor.textColor,
                        ]
                    )
                )
                storage.endEditing()
                renderedLengths.append(contentsOf: newLines.map { ($0.text as NSString).length + 1 })
                renderedCount = lines.count
            }
            renderedFirstID = firstID

            if searchQuery != lastSearchQuery || wasReset {
                lastSearchQuery = searchQuery
                highlight(searchQuery, in: textView)
            }

            if let scrollTarget, scrollTarget != lastScrollTarget {
                lastScrollTarget = scrollTarget
                scroll(to: scrollTarget, lines: lines, textView: textView)
            } else if isFollowing {
                scrollToBottom(textView)
            }
        }

        private func highlight(_ query: String, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            guard query.count >= 2 else { return }

            let text = storage.string as NSString
            var searchRange = whole
            while searchRange.location < text.length {
                let found = text.range(of: query, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.45),
                    forCharacterRange: found
                )
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(location: next, length: max(0, text.length - next))
            }
        }

        private func scroll(to index: Int, lines: [LogLine], textView: NSTextView) {
            guard lines.indices.contains(index), let storage = textView.textStorage else { return }
            // Character offset of the target line: the lengths of everything
            // before it, plus one newline each.
            let offset = lines[..<index].reduce(0) { $0 + ($1.text as NSString).length + 1 }
            guard offset < storage.length else { return }
            let length = min((lines[index].text as NSString).length, storage.length - offset)
            isProgrammaticallyScrolling = true
            textView.scrollRangeToVisible(NSRange(location: offset, length: length))
            textView.setSelectedRange(NSRange(location: offset, length: length))
            isProgrammaticallyScrolling = false
        }

        private func scrollToBottom(_ textView: NSTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            isProgrammaticallyScrolling = true
            textView.scrollRangeToVisible(NSRange(location: storage.length - 1, length: 1))
            isProgrammaticallyScrolling = false
        }
    }
}
