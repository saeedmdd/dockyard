import Foundation
import Testing

@testable import DockyardCore

/// Exercises `LiveBackend` against a real `container-apiserver`.
///
/// Opt-in: `DOCKYARD_INTEGRATION=1 swift test --filter DockyardIntegrationTests`
/// with the daemon running (`container system start`). T12 extends this with
/// the full create/start/stop/delete lifecycle; T02 only proves the XPC path and
/// the model conversions work against real data.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct LiveBackendTests {
    let backend = LiveBackend()

    @Test func healthReportsARunningServer() async throws {
        let health = try await backend.health()

        #expect(!health.apiServerVersion.isEmpty)
        #expect(health.appRoot.path().contains("com.apple.container"))
        #expect(health.appName.contains("apiserver"))
        // The server sends a sentence, not a semver, so this also pins the
        // parsing in `semanticVersion`.
        #expect(
            health.semanticVersion != nil,
            "could not read a version out of \"\(health.apiServerVersion)\""
        )
        // The whole reason the app pins a version: a mismatch means the XPC
        // protocol may not line up.
        #expect(
            health.matchesLinkedVersion,
            "apiserver is \(health.apiServerVersion) but this build links \(DockyardCore.linkedContainerVersion)"
        )
    }

    @Test func listingContainersSucceedsAndIsSorted() async throws {
        let containers = try await backend.listContainers()

        #expect(containers.map(\.id) == containers.map(\.id).sorted())
        for container in containers {
            #expect(!container.id.isEmpty)
            #expect(!container.image.isEmpty)
            #expect(container.cpus > 0)
            #expect(container.memoryInBytes > 0)
        }
    }

    @Test func listingImagesSucceedsAndFlagsInfrastructure() async throws {
        let images = try await backend.listImages()

        #expect(images.map(\.displayReference) == images.map(\.displayReference).sorted())
        for image in images {
            #expect(image.digest.hasPrefix("sha256:"))
            #expect(!image.reference.isEmpty)
        }
        // The runtime always has its own init image pulled once it has run.
        if images.contains(where: { $0.reference.contains("vminit") }) {
            #expect(images.contains { $0.isInfrastructure })
        }
    }

    /// The cheap list path must not be paying for manifest resolution.
    @Test func imageSizeIsAvailableOnDemand() async throws {
        let images = try await backend.listImages()
        guard let image = images.first(where: { !$0.isInfrastructure }) else {
            // Nothing pulled yet; T12 covers this with a fixture image.
            return
        }

        let size = try await backend.imageSize(reference: image.reference)

        #expect(size >= 0)
    }
}
