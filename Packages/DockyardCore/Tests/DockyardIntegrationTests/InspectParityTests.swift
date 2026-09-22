import Foundation
import Testing

@testable import DockyardCore

/// `container inspect` is the reference for what the Inspect tab shows, so this
/// compares the app's JSON against the CLI's for the same container rather than
/// trusting that the same encoder settings produce the same document.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct InspectParityTests {

    @Test func inspectJSONMatchesTheCLI() async throws {
        let backend = LiveBackend()
        let containers = try await backend.listContainers()
        guard let container = containers.first else {
            // Nothing to inspect on this machine; T12 creates its own fixture.
            return
        }

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
        let backend = LiveBackend()
        guard let item = try await backend.listContainers().first else { return }

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
