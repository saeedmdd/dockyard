import DockyardCore
import SwiftUI

/// A shell inside a running container.
struct TerminalTab: View {
    let container: ContainerItem
    @Environment(AppModel.self) private var model

    @State private var session: (any ExecSessionHandle)?
    @State private var state: State = .idle
    @State private var exitStatus: Int32?

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case ended
        case failed(String)
    }

    var body: some View {
        Group {
            if container.status != .running {
                EmptyListView(
                    symbol: "terminal",
                    title: "Container isn’t running",
                    message: "Start it to open a shell."
                )
            } else {
                switch state {
                case .idle, .connecting:
                    connecting
                case .connected:
                    if let session {
                        terminal(session)
                    }
                case .ended:
                    ended
                case .failed(let message):
                    EmptyListView(symbol: "exclamationmark.triangle", title: "Couldn’t open a shell", message: message)
                }
            }
        }
        .task(id: container.id) {
            // A new container means a new session; the old one is not reusable.
            await teardown()
            guard container.status == .running else { return }
            await connect()
        }
        .onDisappear {
            // Leaving the tab must not leave a shell running inside the
            // container with pipes held open on this side.
            let session = session
            Task { await session?.close() }
        }
    }

    private var connecting: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Opening a shell…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func terminal(_ session: any ExecSessionHandle) -> some View {
        ContainerTerminalView(session: session) { status in
            exitStatus = status
            state = .ended
        }
    }

    private var ended: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(exitStatus.map { "Shell exited (\($0))" } ?? "Shell ended")
                .font(.title3)
            Button("New Session") {
                Task { await connect() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() async {
        state = .connecting
        exitStatus = nil
        do {
            session = try await model.backend.exec(ExecRequest(containerID: container.id))
            state = .connected
        } catch {
            state = .failed(DockyardError(mapping: error).errorDescription ?? "Unknown error")
        }
    }

    private func teardown() async {
        await session?.close()
        session = nil
        state = .idle
    }
}
