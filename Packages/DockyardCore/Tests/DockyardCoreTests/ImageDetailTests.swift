import Foundation
import Testing

@testable import DockyardCore

@Suite struct ImageDetailModelTests {

    private func detail(variants: [ImageVariant]) -> ImageDetail {
        ImageDetail(
            reference: "docker.io/library/nginx:latest",
            displayReference: "nginx:latest",
            digest: "sha256:abcdef0123456789",
            mediaType: "application/vnd.oci.image.index.v1+json",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            variants: variants
        )
    }

    private func variant(platform: String, size: Int64 = 1000) -> ImageVariant {
        ImageVariant(
            platform: platform, digest: "sha256:\(platform)", sizeBytes: size,
            entrypoint: [], command: ["sh"], workingDirectory: nil, user: nil,
            environment: [:], labels: [:], stopSignal: nil
        )
    }

    /// An image reference resolves to several platform builds, and the cost on
    /// disk is all of them together.
    @Test func totalSizeSumsEveryVariant() {
        let image = detail(variants: [
            variant(platform: "linux/arm64", size: 7_000_000),
            variant(platform: "linux/amd64", size: 7_500_000),
        ])
        #expect(image.totalSizeBytes == 14_500_000)
    }

    /// This Mac runs arm64, so that is the build worth showing first.
    @Test func preferredVariantIsTheNativeOne() {
        let image = detail(variants: [
            variant(platform: "linux/amd64"),
            variant(platform: "linux/arm64"),
        ])
        #expect(image.preferredVariant?.platform == "linux/arm64")
    }

    @Test func preferredVariantFallsBackWhenNothingIsNative() {
        let image = detail(variants: [variant(platform: "linux/s390x")])
        #expect(image.preferredVariant?.platform == "linux/s390x")
    }

    @Test func imageWithNoVariantsHasNoPreferredOne() {
        let image = detail(variants: [])
        #expect(image.preferredVariant == nil)
        #expect(image.totalSizeBytes == 0)
    }

    /// Attestation manifests are not builds; the CLI skips them and so does
    /// this, or an image would list a phantom "unknown/unknown" platform and
    /// count its bytes toward the total.
    @Test func attestationPlatformIsRecognised() {
        #expect(ImageVariant.attestationPlatform == "unknown/unknown")
        let real = variant(platform: "linux/arm64")
        #expect(real.platform != ImageVariant.attestationPlatform)
    }

    @Test func variantDigestIsShortenedForDisplay() {
        let variant = ImageVariant(
            platform: "linux/arm64", digest: "sha256:0123456789abcdef0123", sizeBytes: 0,
            entrypoint: [], command: [], workingDirectory: nil, user: nil,
            environment: [:], labels: [:], stopSignal: nil
        )
        #expect(variant.shortDigest == "0123456789ab")
    }
}

@MainActor
@Suite struct ImageActionTests {

    private func store(images: [ImageItem]) -> (ImageStore, MockBackend) {
        let backend = MockBackend(images: images)
        return (ImageStore(backend: backend), backend)
    }

    @Test func deleteRemovesTheImageAndReportsReclaimedSpace() async {
        let (store, _) = store(images: [.stub()])
        await store.refresh()

        let result = await store.delete("docker.io/library/alpine:3.20")

        #expect(result?.reclaimedBytes == 4_000_000)
        #expect(store.items.isEmpty)
        #expect(store.actionError == nil)
    }

    /// The runtime needs its builder and init images; deleting one would break
    /// the system in a way that is hard to diagnose later.
    @Test func infrastructureImagesCannotBeDeleted() async {
        let (store, _) = store(images: [
            .stub(reference: "ghcr.io/apple/containerization/vminit:0.33.3", isInfrastructure: true)
        ])
        await store.refresh()

        let result = await store.delete("ghcr.io/apple/containerization/vminit:0.33.3")

        #expect(result == nil)
        #expect(store.actionError != nil)
        #expect(store.items.count == 1, "the image must still be there")
    }

    /// A failed delete must not be wiped by the refresh that follows.
    @Test func deleteFailureSurvivesTheRefresh() async {
        let (store, backend) = store(images: [.stub()])
        await store.refresh()
        backend.setFailure(.upstream(code: "internalError", message: "image is in use"))

        _ = await store.delete("docker.io/library/alpine:3.20")

        #expect(store.actionError == .upstream(code: "internalError", message: "image is in use"))
    }

    @Test func tagAddsASecondReferenceToTheSameImage() async {
        let (store, _) = store(images: [.stub()])
        await store.refresh()

        let ok = await store.tag("docker.io/library/alpine:3.20", as: "myalpine:dev")

        #expect(ok)
        #expect(store.items.contains { $0.reference == "myalpine:dev" })
        #expect(store.items.contains { $0.reference == "docker.io/library/alpine:3.20" })
    }

    /// Deleting an image a container was created from leaves that container
    /// unable to start, so the UI needs to know before it asks.
    @Test func containersUsingAnImageAreFound() async {
        let (store, _) = store(images: [.stub()])
        await store.refresh()
        let image = store.items[0]
        let containers = [
            ContainerItem.stub(id: "web", image: "docker.io/library/alpine:3.20"),
            ContainerItem.stub(id: "other", image: "docker.io/library/nginx:latest"),
            ContainerItem.stub(id: "second", image: "docker.io/library/alpine:3.20"),
        ]

        let users = store.containersUsing(image, in: containers)

        #expect(users.map(\.id) == ["web", "second"])
    }

    @Test func imageWithNoContainersHasNoUsers() async {
        let (store, _) = store(images: [.stub()])
        await store.refresh()

        #expect(store.containersUsing(store.items[0], in: []).isEmpty)
    }
}

@MainActor
@Suite struct ImageDetailStoreTests {

    @Test func selectingLoadsDetail() async {
        let backend = MockBackend(images: [.stub()])
        let store = ImageDetailStore(backend: backend)

        await store.select("docker.io/library/alpine:3.20")

        #expect(store.detail?.variants.count == 2)
        #expect(backend.calls.imageDetail == 1)
    }

    @Test func reselectingDoesNotRefetch() async {
        let backend = MockBackend(images: [.stub()])
        let store = ImageDetailStore(backend: backend)

        await store.select("docker.io/library/alpine:3.20")
        await store.select("docker.io/library/alpine:3.20")

        #expect(backend.calls.imageDetail == 1)
    }

    /// Resolving an image costs an index fetch plus a manifest and config per
    /// platform, so the JSON is only fetched when its tab is opened.
    @Test func inspectJSONIsOnlyFetchedOnDemand() async {
        let backend = MockBackend(images: [.stub()])
        let store = ImageDetailStore(backend: backend)

        await store.select("docker.io/library/alpine:3.20")
        #expect(backend.calls.imageInspect == 0)

        await store.loadInspectJSON()
        await store.loadInspectJSON()

        #expect(backend.calls.imageInspect == 1)
        #expect(store.inspectJSON?.contains("alpine") == true)
    }

    @Test func switchingImagesClearsStaleJSON() async {
        let backend = MockBackend(images: [.stub(), .stub(reference: "nginx:latest", displayReference: "nginx:latest")])
        let store = ImageDetailStore(backend: backend)

        await store.select("docker.io/library/alpine:3.20")
        await store.loadInspectJSON()
        await store.select("nginx:latest")

        #expect(store.inspectJSON == nil)
        #expect(store.detail?.reference == "nginx:latest")
    }

    @Test func missingImageEmptiesThePane() async {
        let store = ImageDetailStore(backend: MockBackend(images: []))

        await store.select("nope:latest")

        #expect(store.detail == nil)
        #expect(store.lastError != nil)
    }
}
