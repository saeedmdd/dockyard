import AppKit
import DockyardCore
import SwiftUI

/// A read-only monospaced view for a batch of lines that arrives all at once.
///
/// `TranscriptView` stacks one SwiftUI `Text` per line, which is fine for the
/// handful a `system start` prints and wrong for a log: a day of the runtime's
/// output is hundreds of lines and the ceiling is `SystemStore.maximumLogLines`.
/// Stacking that many views makes the whole window's view tree enormous — an
/// accessibility walk of it took long enough to time out — while an
/// `NSTextView` holds it in one text storage.
///
/// This is the simpler sibling of `LogTextView`: there is no tailing, no
/// following and no search, because the text is replaced wholesale each time
/// the user asks for it.
struct PlainTextLogView: NSViewRepresentable {
    /// Read inside `updateNSView` rather than compared by SwiftUI; see
    /// `LogTextView` for what comparing the array itself costs.
    let store: SystemStore
    /// What SwiftUI actually compares: one integer per read.
    let version: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.render(store.logLines, version: version)
    }

    @MainActor
    final class Coordinator {
        var textView: NSTextView?
        private var renderedVersion: Int?

        func render(_ lines: [CLILine], version: Int) {
            guard renderedVersion != version, let textView else { return }
            renderedVersion = version
            textView.string = lines.map(\.text).joined(separator: "\n")
            // `log show` puts its header first and the newest entry last, so
            // the end is what someone diagnosing a problem wants to see.
            textView.scrollToEndOfDocument(nil)
        }
    }
}
