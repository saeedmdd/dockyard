import AppKit
import DockyardCore
import SwiftTerm
import SwiftUI

/// A VT100 terminal wired to a process inside a container.
///
/// SwiftTerm does the emulation. Writing one would mean implementing decades of
/// escape-sequence behaviour that every shell, editor and pager depends on.
struct ContainerTerminalView: NSViewRepresentable {
    let session: any ExecSessionHandle
    let onExit: @MainActor (Int32) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onExit: onExit)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Not `@MainActor`: `TerminalViewDelegate` is nonisolated, and marking the
    /// conformance main-actor makes the compiler reject it as a data race.
    /// Everything that touches the view is hopped onto the main actor instead.
    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        private let session: any ExecSessionHandle
        private let onExit: @MainActor (Int32) -> Void
        private weak var view: TerminalView?
        private var readerTask: Task<Void, Never>?
        private var exitTask: Task<Void, Never>?

        init(session: any ExecSessionHandle, onExit: @escaping @MainActor (Int32) -> Void) {
            self.session = session
            self.onExit = onExit
        }

        func attach(to view: TerminalView) {
            self.view = view

            readerTask = Task { [session] in
                for await chunk in session.output {
                    guard !Task.isCancelled else { return }
                    // SwiftTerm wants bytes, and feeding it the raw stream is
                    // what makes colours and cursor movement work. The view is
                    // main-actor bound, so the hop happens here.
                    await MainActor.run {
                        view.feed(byteArray: ArraySlice([UInt8](chunk)))
                    }
                }
            }

            exitTask = Task { [session, onExit] in
                let status = await session.waitForExit()
                guard !Task.isCancelled else { return }
                await MainActor.run { onExit(status) }
            }
        }

        func detach() {
            readerTask?.cancel()
            exitTask?.cancel()
            readerTask = nil
            exitTask = nil
            let session = session
            Task { await session.close() }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { [session] in await session.send(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Without this, full-screen programs draw at the wrong size.
            Task { [session] in await session.resize(columns: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
