import Foundation
import Testing

@testable import DockyardCore

/// Image operations against the real content store.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct ImageIntegrationTests {

    @Test func tagThenDeleteLeavesTheOriginal() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let tag = "\(fixture.prefix):tagged"

            try await fixture.backend.tagImage(reference: IntegrationFixture.testImage, newReference: tag)

            let tagged = try await fixture.backend.listImages()
            #expect(tagged.contains { $0.reference.contains(fixture.prefix) })

            let reference = try #require(
                tagged.first { $0.reference.contains(fixture.prefix) }?.reference
            )
            _ = try await fixture.backend.deleteImage(reference: reference)

            let afterDelete = try await fixture.backend.listImages()
            #expect(!afterDelete.contains { $0.reference.contains(fixture.prefix) })
            // Deleting one reference must not remove the image others point at.
            #expect(afterDelete.contains { $0.reference == IntegrationFixture.testImage })
        }
    }

    /// Deleting a tag that shares every layer frees nothing, and the app is
    /// expected to report that rather than claiming the image's full size.
    @Test func deletingASharedTagReclaimsNothing() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let tag = "\(fixture.prefix):shared"
            try await fixture.backend.tagImage(reference: IntegrationFixture.testImage, newReference: tag)

            let reference = try #require(
                try await fixture.backend.listImages()
                    .first { $0.reference.contains(fixture.prefix) }?.reference
            )
            let result = try await fixture.backend.deleteImage(reference: reference)

            #expect(result.reclaimedBytes == 0, "layers shared with alpine:3.20 must not be freed")
        }
    }

    /// The runtime needs its own builder and init images, so the app refuses.
    @Test func infrastructureImagesAreProtected() async throws {
        try await withFixture { fixture in
            let images = try await fixture.backend.listImages()
            guard let infra = images.first(where: \.isInfrastructure) else {
                // Nothing marked infrastructure on this machine.
                return
            }

            await #expect(throws: DockyardError.self) {
                _ = try await fixture.backend.deleteImage(reference: infra.reference)
            }
            #expect(try await fixture.backend.listImages().contains { $0.reference == infra.reference })
        }
    }

    @Test func imageDetailResolvesVariantsAndSize() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()

            let detail = try await fixture.backend.imageDetail(reference: IntegrationFixture.testImage)

            #expect(!detail.variants.isEmpty)
            #expect(detail.totalSizeBytes > 0)
            // Attestation manifests are filtered out; they are metadata rather
            // than builds and would otherwise inflate the size.
            #expect(!detail.variants.contains { $0.platform == ImageVariant.attestationPlatform })
            #expect(detail.digest.hasPrefix("sha256:"))
        }
    }

    @Test func pullingAnImageThatIsAlreadyPresentSucceeds() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()

            var sawProgress = false
            for try await _ in fixture.backend.pullImage(reference: IntegrationFixture.testImage, platform: nil) {
                sawProgress = true
            }

            #expect(sawProgress, "even a cached pull reports its phases")
            #expect(try await fixture.backend.listImages().contains { $0.reference == IntegrationFixture.testImage })
        }
    }

    @Test func pullingSomethingThatDoesNotExistFails() async throws {
        try await withFixture { fixture in
            await #expect(throws: (any Error).self) {
                for try await _ in fixture.backend.pullImage(
                    reference: "docker.io/library/dockyard-no-such-image:0.0.0",
                    platform: nil
                ) {}
            }
        }
    }
}


