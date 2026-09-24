import Foundation
import Testing

@testable import DockyardCore

/// `container inspect` is the reference for what the Inspect tab shows, so this
/// compares the app's JSON against the CLI's for the same container rather than
/// trusting that the same encoder settings produce the same document.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct InspectParityTests {

    /// Inspects a container this test owns.
    ///
    /// It used to take whatever `listContainers().first` returned, which is a
    /// race: another suite can delete that container between the list and the
    /// inspect, and the CLI then prints a truncated document that fails to
    /// parse. Harmless when this was the only suite creating containers; not
    /// once compose projects come and go alongside it.
    @Test func inspectJSONMatchesTheCLI() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("inspect"))
            try await Self.compareInspect(id: id, backend: fixture.backend)
        }
    }

    private static func compareInspect(id: String, backend: LiveBackend) async throws {
        let container = try #require(try await backend.listContainers().first { $0.id == id })

        let appJSON = try await backend.containerInspectJSON(id: container.id)
        let cliJSON = try await Self.cliInspect(id: container.id)

        let appObject = try #require(
            JSONSerialization.jsonObject(with: Data(appJSON.utf8)) as? [String: Any],
            "app inspect output is not a JSON object"
        )
        // The CLI inspects a list of containers, so it emits an array.
        let cliArray = try #require(
            JSONSerialization.jsonObject(with: Data(cliJSON.utf8)) as? [[String: Any]],
            "CLI inspect output is not a JSON array"
        )
        let cliObject = try #require(cliArray.first)

        #expect(
            Set(appObject.keys) == Set(cliObject.keys),
            "top-level keys differ — app: \(appObject.keys.sorted()), CLI: \(cliObject.keys.sorted())"
        )

        // Spot-check the identifying fields rather than deep-comparing: dates
        // are formatted differently by the two encoders.
        let appConfig = appObject["configuration"] as? [String: Any]
        let cliConfig = cliObject["configuration"] as? [String: Any]
        #expect(appConfig?["id"] as? String == container.id)
        #expect(appConfig?["id"] as? String == cliConfig?["id"] as? String)
        #expect(Set(appConfig?.keys ?? [:].keys) == Set(cliConfig?.keys ?? [:].keys))
    }

    /// The detail model must agree with the list model about the same container.
    @Test func detailAgreesWithTheListEntry() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let id = try await fixture.create(fixture.sleeperSpec("detail"))
            try await Self.compareDetail(id: id, backend: fixture.backend)
        }
    }

    private static func compareDetail(id: String, backend: LiveBackend) async throws {
        let item = try #require(try await backend.listContainers().first { $0.id == id })

        let detail = try await backend.containerDetail(id: item.id)

        #expect(detail.id == item.id)
        #expect(detail.image == item.image)
        #expect(detail.status == item.status)
        #expect(detail.cpus == item.cpus)
        #expect(detail.memoryInBytes == item.memoryInBytes)
        #expect(detail.ports == item.ports)
    }

    @Test func detailOfAMissingContainerFails() async {
        let backend = LiveBackend()
        await #expect(throws: DockyardError.self) {
            _ = try await backend.containerDetail(id: "dockyard-does-not-exist-\(UUID().uuidString)")
        }
    }

    private static func cliInspect(id: String) async throws -> String {
        let lines = try await CLIRunner().runToCompletion(["inspect", id])
        return lines.filter { $0.stream == .stdout }.map(\.text).joined(separator: "\n")
    }
}
