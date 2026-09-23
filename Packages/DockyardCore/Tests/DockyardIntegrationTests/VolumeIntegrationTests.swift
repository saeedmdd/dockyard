import Foundation
import Testing

@testable import DockyardCore

/// Volumes against the real runtime.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct VolumeIntegrationTests {

    /// Runs a test with a fixture-namespaced volume name.
    ///
    /// Cleanup is left to `withFixture`, which removes containers before
    /// volumes — deleting the volume here would fail whenever a container in
    /// the test still mounts it, and `try?` would hide that.
    private func withVolume(
        _ body: (IntegrationFixture, String) async throws -> Void
    ) async throws {
        try await withFixture { fixture in
            try await body(fixture, fixture.name("vol"))
        }
    }

    @Test func createListAndDelete() async throws {
        try await withVolume { fixture, name in
            var spec = VolumeSpec()
            spec.name = name

            let created = try await fixture.backend.createVolume(spec)
            #expect(created.name == name)
            #expect(created.driver == "local")

            let listed = try await fixture.backend.listVolumes()
            #expect(listed.contains { $0.name == name })
            // The runtime records where it keeps it.
            #expect(!(listed.first { $0.name == name }?.source.isEmpty ?? true))

            try await fixture.backend.deleteVolume(name: name)
            #expect(try await !fixture.backend.listVolumes().contains { $0.name == name })
        }
    }

    @Test func creatingTheSameNameTwiceFails() async throws {
        try await withVolume { fixture, name in
            var spec = VolumeSpec()
            spec.name = name
            _ = try await fixture.backend.createVolume(spec)

            await #expect(throws: DockyardError.self) {
                _ = try await fixture.backend.createVolume(spec)
            }
        }
    }

    @Test func labelsSurviveTheRoundTrip() async throws {
        try await withVolume { fixture, name in
            var spec = VolumeSpec()
            spec.name = name
            spec.labels = [.init(key: "dockyard.test", value: "t15")]

            _ = try await fixture.backend.createVolume(spec)
            let listed = try await fixture.backend.listVolumes().first { $0.name == name }

            #expect(listed?.labels["dockyard.test"] == "t15")
        }
    }

    @Test func diskUsageIsReported() async throws {
        try await withVolume { fixture, name in
            var spec = VolumeSpec()
            spec.name = name
            _ = try await fixture.backend.createVolume(spec)

            let bytes = try await fixture.backend.volumeDiskUsage(name: name)

            #expect(bytes >= 0)
        }
    }

    /// A container created with the volume mounted must report it, which is
    /// what the delete guard relies on.
    @Test func aMountedVolumeIsVisibleOnTheContainer() async throws {
        try await withVolume { fixture, name in
            try await fixture.ensureTestImage()
            var volumeSpec = VolumeSpec()
            volumeSpec.name = name
            _ = try await fixture.backend.createVolume(volumeSpec)

            var spec = fixture.sleeperSpec("mounts")
            spec.volumes = ["\(name):/data"]
            let id = try await fixture.create(spec)

            let detail = try await fixture.backend.containerDetail(id: id)

            #expect(
                detail.mounts.contains { $0.volumeName == name },
                "expected the volume in \(detail.mounts.map { $0.volumeName ?? $0.source })"
            )
        }
    }

    @Test func deletingAMissingVolumeFails() async throws {
        try await withFixture { fixture in
            await #expect(throws: DockyardError.self) {
                try await fixture.backend.deleteVolume(name: fixture.name("never-created"))
            }
        }
    }
}
