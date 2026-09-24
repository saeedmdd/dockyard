import Foundation
import Testing

@testable import DockyardCore

/// Scratch space for a test that needs real containers and images.
///
/// Everything it creates is named with a unique prefix, and everything with
/// that prefix is removed afterwards — including when the test fails, which is
/// exactly when leftovers are most likely. These tests run against whatever
/// daemon the developer is using, so leaving a stray container behind would be
/// rummaging in someone's workspace.
struct IntegrationFixture: Sendable {
    /// An image small enough to pull quickly and present on most machines.
    static let testImage = "docker.io/library/alpine:3.20"

    let backend = LiveBackend()
    /// Unique per fixture, so concurrent or interrupted runs never collide.
    let prefix: String

    init() {
        prefix = "dockyard-it-\(UUID().uuidString.prefix(8).lowercased())"
    }

    func name(_ suffix: String) -> String {
        "\(prefix)-\(suffix)"
    }

    /// A spec for a container that sits still long enough to be inspected.
    func sleeperSpec(_ suffix: String, seconds: Int = 120) -> RunSpec {
        var spec = RunSpec(image: Self.testImage)
        spec.name = name(suffix)
        spec.command = "sleep \(seconds)"
        return spec
    }

    /// Creates a container and returns its id.
    @discardableResult
    func create(_ spec: RunSpec) async throws -> String {
        var created: String?
        for try await update in backend.createContainer(spec: spec) {
            if case .created(let id) = update { created = id }
        }
        return try #require(created, "the runtime reported no id for \(spec.name)")
    }

    /// Makes sure the fixture's image is present, pulling it if not.
    func ensureTestImage() async throws {
        let images = try await backend.listImages()
        guard !images.contains(where: { $0.reference == Self.testImage }) else { return }
        for try await _ in backend.pullImage(reference: Self.testImage, platform: nil) {}
    }

    /// Removes every container, image and volume this fixture could have
    /// created.
    ///
    /// Order matters: a volume cannot be deleted while a container still
    /// mounts it, so containers go first. Getting this wrong leaves volumes
    /// behind, silently, because each delete is best-effort.
    func cleanUp() async {
        if let containers = try? await backend.listContainers() {
            for container in containers where container.id.hasPrefix(prefix) {
                try? await backend.deleteContainer(id: container.id, force: true)
            }
        }
        if let volumes = try? await backend.listVolumes() {
            for volume in volumes where volume.name.hasPrefix(prefix) {
                try? await backend.deleteVolume(name: volume.name)
            }
        }
        if let networks = try? await backend.listNetworks() {
            for network in networks where network.name.hasPrefix(prefix) && !network.isBuiltin {
                try? await backend.deleteNetwork(name: network.name)
            }
        }
        if let images = try? await backend.listImages() {
            for image in images where image.reference.contains(prefix) {
                _ = try? await backend.deleteImage(reference: image.reference)
            }
        }
    }
}

/// Runs `body` with a fixture, cleaning up whatever it left behind.
///
/// Cleanup runs on the failure path too: `defer` cannot await, so the error is
/// caught, the fixture is torn down, and the error is rethrown.
func withFixture(
    _ body: (IntegrationFixture) async throws -> Void
) async throws {
    try await ensureDaemonRunning()
    let fixture = IntegrationFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanUp()
        throw error
    }
    await fixture.cleanUp()
}

/// The same thing for a test that drives a store.
///
/// Stores are `@MainActor`, and a closure handed to the plain `withFixture`
/// arrives without isolation, so every call inside it would be a cross-actor
/// hop the compiler refuses. Declaring the body `@MainActor` keeps the test
/// readable instead of wrapping each line in `MainActor.run`.
@MainActor
func withMainActorFixture(
    _ body: @MainActor (IntegrationFixture) async throws -> Void
) async throws {
    try await ensureDaemonRunning()
    let fixture = IntegrationFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanUp()
        throw error
    }
    await fixture.cleanUp()
}

/// Starts the container system if it is not already up.
///
/// A developer running these tests should not have to remember to start the
/// daemon first, and a failure here is much clearer than every test failing
/// with an XPC error.
func ensureDaemonRunning() async throws {
    let backend = LiveBackend()
    if (try? await backend.health()) != nil { return }

    let runner = CLIRunner()
    guard runner.isInstalled else {
        Issue.record("container CLI not found at \(runner.executablePath); integration tests need it")
        throw DockyardError.cliMissing(path: runner.executablePath)
    }
    for try await _ in runner.systemStart() {}
    _ = try await backend.health()
}
