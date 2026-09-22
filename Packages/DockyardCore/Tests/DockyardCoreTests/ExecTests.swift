import Foundation
import Testing

@testable import DockyardCore

@Suite struct ExecRequestTests {

    /// Minimal images routinely have only `/bin/sh`, so bash is tried first but
    /// is never assumed.
    @Test func defaultsTryBashThenSh() {
        let request = ExecRequest(containerID: "web")
        #expect(request.shellCandidates == ["/bin/bash", "/bin/sh"])
        #expect(request.allocateTerminal)
    }

    @Test func sizeDefaultsToAConventionalTerminal() {
        let request = ExecRequest(containerID: "web")
        #expect(request.columns == 80)
        #expect(request.rows == 24)
    }

    @Test func candidatesAndSizeCanBeOverridden() {
        let request = ExecRequest(
            containerID: "web",
            shellCandidates: ["/usr/bin/fish"],
            allocateTerminal: false,
            columns: 120,
            rows: 40
        )
        #expect(request.shellCandidates == ["/usr/bin/fish"])
        #expect(!request.allocateTerminal)
        #expect(request.columns == 120)
        #expect(request.rows == 40)
    }
}

@MainActor
@Suite struct ExecBackendTests {

    @Test func execRequiresARunningContainer() async {
        let backend = MockBackend(containers: [.stub(id: "web", status: .stopped)])

        await #expect(throws: DockyardError.self) {
            _ = try await backend.exec(ExecRequest(containerID: "web"))
        }
    }

    @Test func execOnARunningContainerReturnsASession() async throws {
        let backend = MockBackend(containers: [.stub(id: "web", status: .running)])

        let session = try await backend.exec(ExecRequest(containerID: "web"))

        #expect(backend.calls.exec == 1)
        await session.close()
    }

    @Test func execOnAMissingContainerFails() async {
        let backend = MockBackend(containers: [])

        await #expect(throws: DockyardError.self) {
            _ = try await backend.exec(ExecRequest(containerID: "nope"))
        }
    }

    /// The session has to carry resize through, or full-screen programs draw at
    /// the wrong size.
    @Test func resizeReachesTheSession() async throws {
        let backend = MockBackend(containers: [.stub(id: "web", status: .running)])
        let session = try await backend.exec(ExecRequest(containerID: "web"))

        await session.resize(columns: 132, rows: 43)

        let mock = try #require(session as? MockExecSession)
        #expect(mock.lastSize?.columns == 132)
        #expect(mock.lastSize?.rows == 43)
        await session.close()
    }

    @Test func closingASessionIsRecorded() async throws {
        let backend = MockBackend(containers: [.stub(id: "web", status: .running)])
        let session = try await backend.exec(ExecRequest(containerID: "web"))

        await session.close()

        let mock = try #require(session as? MockExecSession)
        #expect(mock.isClosed)
    }

    @Test func outputStreamFinishesWhenTheSessionCloses() async throws {
        let backend = MockBackend(containers: [.stub(id: "web", status: .running)])
        let session = try await backend.exec(ExecRequest(containerID: "web"))

        let collector = Task {
            var chunks = 0
            for await _ in session.output { chunks += 1 }
            return chunks
        }
        await session.send(Data("one".utf8))
        await session.close()

        // Finishes rather than hanging, which is what lets the terminal view
        // tear down cleanly.
        _ = await collector.value
    }
}
