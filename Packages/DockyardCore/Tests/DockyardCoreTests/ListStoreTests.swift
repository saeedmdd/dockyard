import Foundation
import Testing

@testable import DockyardCore

@MainActor
@Suite struct ContainerStoreTests {

    @Test func refreshLoadsItems() async {
        let store = ContainerStore(backend: MockBackend(containers: [.stub(id: "web"), .stub(id: "db")]))

        #expect(store.isLoadingInitially)
        await store.refresh()

        #expect(store.items.map(\.id) == ["web", "db"])
        #expect(!store.isLoadingInitially)
        #expect(store.lastError == nil)
    }

    @Test func runningFiltersByStatus() async {
        let store = ContainerStore(
            backend: MockBackend(containers: [
                .stub(id: "web", status: .running),
                .stub(id: "db", status: .stopped),
                .stub(id: "cache", status: .running),
            ])
        )
        await store.refresh()

        #expect(store.running.map(\.id) == ["web", "cache"])
    }

    /// A stopped daemon owns the whole window, so the list must not add its own
    /// error on top — and must not keep showing containers that are gone.
    @Test func daemonDownClearsRowsWithoutReportingAnError() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        let store = ContainerStore(backend: backend)
        await store.refresh()
        #expect(store.items.count == 1)

        backend.setFailure(.daemonUnreachable("XPC connection error: Connection invalid"))
        await store.refresh()

        #expect(store.items.isEmpty, "stale rows must not survive the daemon going away")
        #expect(store.lastError == nil, "the daemon-down screen already explains this")
    }

    /// A genuine failure is worth showing, and must not wipe the list.
    @Test func otherErrorsAreReportedAndRowsKept() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        let store = ContainerStore(backend: backend)
        await store.refresh()

        backend.setFailure(.upstream(code: "internalError", message: "something broke"))
        await store.refresh()

        #expect(store.lastError == .upstream(code: "internalError", message: "something broke"))
        #expect(store.items.count == 1, "a transient failure should not blank the table")
    }

    @Test func recoveringClearsTheError() async {
        let backend = MockBackend(containers: [.stub(id: "web")])
        let store = ContainerStore(backend: backend)
        backend.setFailure(.other("blip"))
        await store.refresh()
        #expect(store.lastError != nil)

        backend.setFailure(nil)
        await store.refresh()

        #expect(store.lastError == nil)
        #expect(store.items.count == 1)
    }

    @Test func lookupById() async {
        let store = ContainerStore(backend: MockBackend(containers: [.stub(id: "web")]))
        await store.refresh()

        #expect(store.item(id: "web")?.id == "web")
        #expect(store.item(id: "nope") == nil)
    }
}

@MainActor
@Suite struct ImageStoreTests {

    private func store(showingInfrastructure: Bool = false) -> ImageStore {
        let store = ImageStore(
            backend: MockBackend(images: [
                .stub(reference: "docker.io/library/alpine:3.20", displayReference: "alpine:3.20"),
                .stub(
                    reference: "ghcr.io/apple/containerization/vminit:0.33.3",
                    displayReference: "ghcr.io/apple/containerization/vminit:0.33.3",
                    isInfrastructure: true
                ),
            ])
        )
        store.showsInfrastructure = showingInfrastructure
        return store
    }

    /// The runtime's own builder and vminit images are noise for a user who
    /// just wants to see what they pulled.
    @Test func infrastructureImagesAreHiddenByDefault() async {
        let store = store()
        await store.refresh()

        #expect(store.items.count == 2)
        #expect(store.visibleItems.map(\.displayReference) == ["alpine:3.20"])
        #expect(store.infrastructureCount == 1)
    }

    @Test func infrastructureImagesCanBeShown() async {
        let store = store(showingInfrastructure: true)
        await store.refresh()

        #expect(store.visibleItems.count == 2)
    }

    @Test func daemonDownClearsRowsWithoutReportingAnError() async {
        let backend = MockBackend(images: [.stub()])
        let store = ImageStore(backend: backend)
        await store.refresh()

        backend.setFailure(.daemonTimeout("no answer"))
        await store.refresh()

        #expect(store.items.isEmpty)
        #expect(store.lastError == nil)
    }
}
