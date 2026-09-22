import Foundation
import Testing

@testable import DockyardCore

/// Checks the seam itself: anything written against `ContainerBackend` must work
/// with a substitute implementation, which is what makes the stores in later
/// tasks testable without a daemon.
@Suite struct BackendContractTests {

    @Test func mockSatisfiesTheProtocolAndCountsCalls() async throws {
        let backend = MockBackend(
            containers: [.stub(id: "web"), .stub(id: "db", status: .stopped)],
            images: [.stub()]
        )

        let containers = try await backend.listContainers()
        let images = try await backend.listImages()
        _ = try await backend.health()

        #expect(containers.count == 2)
        #expect(images.count == 1)
        #expect(backend.calls == .init(health: 1, listContainers: 1, listImages: 1, imageSize: 0))
    }

    @Test func failuresPropagateAsDockyardErrors() async {
        let backend = MockBackend()
        backend.setFailure(.daemonUnreachable("XPC connection error: Connection invalid"))

        await #expect(throws: DockyardError.daemonUnreachable("XPC connection error: Connection invalid")) {
            _ = try await backend.listContainers()
        }
    }

    /// Callers hold the protocol, never a concrete type.
    @Test func backendIsUsableThroughTheProtocolExistential() async throws {
        let backend: any ContainerBackend = MockBackend(containers: [.stub(id: "only")])
        let containers = try await backend.listContainers()
        #expect(containers.map(\.id) == ["only"])
    }
}
