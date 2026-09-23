import Foundation
import Testing

@testable import DockyardCore

/// Networks against the real runtime.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct NetworkIntegrationTests {

    @Test func theBuiltinNetworkIsPresentAndProtected() async throws {
        try await withFixture { fixture in
            let networks = try await fixture.backend.listNetworks()

            let builtinCandidate = networks.first(where: \.isBuiltin)
            let builtin = try #require(builtinCandidate, "expected a built-in network")
            #expect(builtin.subnet != nil, "a running network has a subnet")
            #expect(builtin.gateway != nil)

            await #expect(throws: DockyardError.self) {
                try await fixture.backend.deleteNetwork(name: builtin.name)
            }
            #expect(try await fixture.backend.listNetworks().contains { $0.name == builtin.name })
        }
    }

    @Test func createListAndDelete() async throws {
        try await withFixture { fixture in
            let name = fixture.name("net")
            var spec = NetworkSpec()
            spec.name = name

            let created = try await fixture.backend.createNetwork(spec)
            #expect(created.name == name)
            #expect(!created.isBuiltin)

            #expect(try await fixture.backend.listNetworks().contains { $0.name == name })

            try await fixture.backend.deleteNetwork(name: name)
            #expect(try await !fixture.backend.listNetworks().contains { $0.name == name })
        }
    }

    /// A container attached to a network reports it, which is what the delete
    /// guard reads.
    @Test func aContainerReportsTheNetworkItIsOn() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let name = fixture.name("net")
            var networkSpec = NetworkSpec()
            networkSpec.name = name
            _ = try await fixture.backend.createNetwork(networkSpec)

            var spec = fixture.sleeperSpec("netjoin")
            spec.networks = [name]
            let id = try await fixture.create(spec)
            try await fixture.backend.startContainer(id: id)

            let containers = try await fixture.backend.listContainers()
            let container = try #require(containers.first { $0.id == id })

            #expect(
                container.networks.contains { $0.network == name },
                "expected \(name) in \(container.networks.map(\.network))"
            )

            // Tidy up before the fixture removes the network.
            try await fixture.backend.deleteContainer(id: id, force: true)
            try? await fixture.backend.deleteNetwork(name: name)
        }
    }

    @Test func deletingAMissingNetworkFails() async throws {
        try await withFixture { fixture in
            await #expect(throws: DockyardError.self) {
                try await fixture.backend.deleteNetwork(name: fixture.name("never-made"))
            }
        }
    }
}
