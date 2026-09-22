import Foundation
import Testing

@testable import DockyardCore

@MainActor
@Suite struct ContainerLifecycleTests {

    private func loadedStore(
        _ containers: [ContainerItem]
    ) async -> (ContainerStore, MockBackend) {
        let backend = MockBackend(containers: containers)
        let store = ContainerStore(backend: backend)
        await store.refresh()
        return (store, backend)
    }

    @Test func startTransitionsTheContainer() async {
        let (store, backend) = await loadedStore([.stub(id: "web", status: .stopped)])

        let ok = await store.start("web")

        #expect(ok)
        #expect(backend.calls.start == 1)
        #expect(store.item(id: "web")?.status == .running)
    }

    @Test func stopTransitionsTheContainer() async {
        let (store, backend) = await loadedStore([.stub(id: "web", status: .running)])

        await store.stop("web")

        #expect(backend.calls.stop == 1)
        #expect(store.item(id: "web")?.status == .stopped)
    }

    @Test func killSendsTheChosenSignal() async {
        let (store, backend) = await loadedStore([.stub(id: "web", status: .running)])

        await store.kill("web", signal: .interrupt)

        #expect(backend.invocations == [.init(id: "web", action: "kill", detail: "SIGINT")])
    }

    @Test func killDefaultsToSIGKILL() async {
        let (store, backend) = await loadedStore([.stub(id: "web", status: .running)])

        await store.kill("web")

        #expect(backend.invocations.first?.detail == "SIGKILL")
    }

    @Test func deleteRemovesTheRow() async {
        let (store, _) = await loadedStore([.stub(id: "web", status: .stopped), .stub(id: "db", status: .stopped)])

        await store.delete("web")

        #expect(store.items.map(\.id) == ["db"])
    }

    /// The runtime refuses to delete a running container without force, and the
    /// UI must not quietly pass force on the user's behalf.
    @Test func deletingARunningContainerWithoutForceFails() async {
        let (store, _) = await loadedStore([.stub(id: "web", status: .running)])

        let ok = await store.delete("web")

        #expect(!ok)
        #expect(store.actionError != nil, "the refresh that follows must not wipe the failure")
        #expect(store.items.map(\.id) == ["web"], "the container must still be there")
    }

    @Test func forceDeleteRemovesARunningContainer() async {
        let (store, backend) = await loadedStore([.stub(id: "web", status: .running)])

        let ok = await store.delete("web", force: true)

        #expect(ok)
        #expect(store.items.isEmpty)
        #expect(backend.invocations.last?.detail == "force")
    }

    // MARK: - Pending state

    /// Booting a VM takes a moment; the row must acknowledge the click at once
    /// rather than sitting unchanged until a poll catches up.
    @Test func pendingActionIsVisibleWhileInFlightAndClearedAfter() async {
        let (store, backend) = await loadedStore([.stub(id: "web", status: .stopped)])
        backend.gateLifecycleCalls()

        let task = Task { await store.start("web") }
        await backend.waitForGatedCall()

        #expect(store.pendingAction(for: "web") == .starting)
        #expect(store.displayStatus(for: store.item(id: "web")!) == "Starting…")

        backend.releaseGate()
        _ = await task.value

        #expect(store.pendingAction(for: "web") == nil)
        #expect(store.displayStatus(for: store.item(id: "web")!) == "Running")
    }

    /// A double-click must not send the command twice.
    @Test func secondActionOnTheSameContainerIsIgnoredWhileOneIsInFlight() async {
        let (store, backend) = await loadedStore([.stub(id: "web", status: .stopped)])

        async let first = store.start("web")
        async let second = store.start("web")
        let results = await [first, second]

        #expect(backend.calls.start == 1, "the second click must not reach the daemon")
        #expect(results.contains(true))
        #expect(results.contains(false))
    }

    @Test func actionsOnDifferentContainersRunIndependently() async {
        let (store, backend) = await loadedStore([
            .stub(id: "web", status: .stopped),
            .stub(id: "db", status: .stopped),
        ])

        async let web = store.start("web")
        async let db = store.start("db")
        _ = await [web, db]

        #expect(backend.calls.start == 2)
        #expect(store.items.allSatisfy { $0.status == .running })
    }

    /// A failure must leave nothing stuck showing "Starting…" forever.
    @Test func failureClearsPendingAndReportsTheError() async {
        let backend = MockBackend(containers: [.stub(id: "web", status: .stopped)])
        let store = ContainerStore(backend: backend)
        await store.refresh()
        backend.setFailure(.upstream(code: "invalidState", message: "mount source missing"))

        let ok = await store.start("web")

        #expect(!ok)
        #expect(store.pendingAction(for: "web") == nil)
        #expect(store.actionError == .upstream(code: "invalidState", message: "mount source missing"))
    }

    // MARK: - Prune

    @Test func pruneRemovesOnlyStoppedContainers() async {
        let (store, _) = await loadedStore([
            .stub(id: "a", status: .stopped),
            .stub(id: "b", status: .running),
            .stub(id: "c", status: .stopped),
        ])

        let result = await store.pruneStopped()

        #expect(result.removed == 2)
        #expect(result.failed == 0)
        #expect(store.items.map(\.id) == ["b"])
    }

    @Test func pruneWithNothingStoppedDoesNothing() async {
        let (store, backend) = await loadedStore([.stub(id: "b", status: .running)])

        let result = await store.pruneStopped()

        #expect(result == (removed: 0, failed: 0))
        #expect(backend.calls.delete == 0)
    }
}
