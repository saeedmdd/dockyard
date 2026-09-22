import Foundation
import Testing

@testable import DockyardCore

/// Running processes inside real containers.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct ExecIntegrationTests {

    @Test func capturingExecReturnsOutputAndExitCode() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("exec"))
            try await fixture.backend.startContainer(id: id)

            let result = try await fixture.backend.execCapturing(
                containerID: id,
                command: ["/bin/sh", "-c", "echo dockyard-hello"]
            )

            #expect(result.output.contains("dockyard-hello"))
            #expect(result.exitCode == 0)
        }
    }

    /// A failing command must report its status rather than looking successful.
    @Test func nonZeroExitIsReported() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("exec-fail"))
            try await fixture.backend.startContainer(id: id)

            let result = try await fixture.backend.execCapturing(
                containerID: id,
                command: ["/bin/sh", "-c", "exit 7"]
            )

            #expect(result.exitCode == 7)
        }
    }

    /// Without a terminal, stderr is separate — and must still be captured, or
    /// error messages would vanish.
    @Test func standardErrorIsCaptured() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("exec-stderr"))
            try await fixture.backend.startContainer(id: id)

            let result = try await fixture.backend.execCapturing(
                containerID: id,
                command: ["/bin/sh", "-c", "echo to-stderr 1>&2"]
            )

            #expect(result.output.contains("to-stderr"))
        }
    }

    /// The exec inherits the container's init process, which is what carries
    /// the image's PATH — without it a bare `ls` would not resolve.
    @Test func environmentIsInheritedFromTheImage() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("exec-env"))
            try await fixture.backend.startContainer(id: id)

            let result = try await fixture.backend.execCapturing(
                containerID: id,
                command: ["/bin/sh", "-c", "echo $PATH"]
            )

            #expect(result.output.contains("/bin"), "expected the image's PATH, got \(result.output)")
        }
    }

    // MARK: - Interactive session

    @Test func interactiveShellEchoesWhatItIsSent() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("exec-tty"))
            try await fixture.backend.startContainer(id: id)

            let session = try await fixture.backend.exec(
                ExecRequest(containerID: id, columns: 100, rows: 30)
            )

            await session.send(Data("echo dockyard-interactive\n".utf8))

            var received = ""
            let deadline = Task {
                try? await Task.sleep(for: .seconds(12))
                await session.close()
            }
            for await chunk in session.output {
                received += String(decoding: chunk, as: UTF8.self)
                if received.contains("dockyard-interactive") { break }
            }
            deadline.cancel()
            await session.close()

            #expect(received.contains("dockyard-interactive"))
        }
    }

    /// Resizing must be accepted while the shell runs; a full-screen program
    /// depends on it to redraw at the right size.
    @Test func resizingAnOpenSessionIsAccepted() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("exec-resize"))
            try await fixture.backend.startContainer(id: id)

            let session = try await fixture.backend.exec(ExecRequest(containerID: id))
            await session.resize(columns: 120, rows: 40)
            await session.send(Data("stty size\n".utf8))

            var received = ""
            let deadline = Task {
                try? await Task.sleep(for: .seconds(12))
                await session.close()
            }
            for await chunk in session.output {
                received += String(decoding: chunk, as: UTF8.self)
                if received.contains("40 120") { break }
            }
            deadline.cancel()
            await session.close()

            #expect(received.contains("40 120"), "expected the resized dimensions, got: \(received)")
        }
    }

    /// Opening a shell in a stopped container must fail with something a user
    /// can read, not an opaque runtime error.
    @Test func execOnAStoppedContainerExplainsItself() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("exec-stopped"))

            await #expect(throws: DockyardError.self) {
                _ = try await fixture.backend.exec(ExecRequest(containerID: id))
            }
        }
    }
}
