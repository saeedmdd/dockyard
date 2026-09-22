import Foundation
import Testing

@testable import DockyardCore

@Suite struct PullProgressTests {

    @Test func startsEmptyAndIndeterminate() {
        let progress = PullProgress()
        #expect(progress.fraction == nil, "no total yet means no honest percentage")
        #expect(progress.bytesSummary == nil)
    }

    @Test func addAndSetAccumulateIndependently() {
        var progress = PullProgress()
        progress.apply([.addItems(3), .addItems(2), .setTotalItems(10)])
        #expect(progress.items == 5)
        #expect(progress.totalItems == 10)

        progress.apply(.setItems(7))
        #expect(progress.items == 7)
    }

    @Test func sizeTotalsAccumulate() {
        var progress = PullProgress()
        progress.apply([.addTotalSize(1000), .addTotalSize(500), .addSize(300)])
        #expect(progress.totalBytes == 1500)
        #expect(progress.bytes == 300)
        #expect(progress.fraction == 0.2)
    }

    /// Bytes move smoothly and are what the user is waiting on, so they win.
    @Test func fractionPrefersBytesOverItems() {
        var progress = PullProgress()
        progress.apply([.setTotalItems(10), .setItems(9), .setTotalSize(100), .setSize(10)])
        #expect(progress.fraction == 0.1)
    }

    @Test func fractionFallsBackToItemsWhenNoSizeIsKnown() {
        var progress = PullProgress()
        progress.apply([.setTotalItems(4), .setItems(1)])
        #expect(progress.fraction == 0.25)
    }

    @Test func fractionIsClampedToOne() {
        var progress = PullProgress()
        progress.apply([.setTotalSize(100), .setSize(250)])
        #expect(progress.fraction == 1)
    }

    /// The pull runs in two phases and each counts its own bytes. Without a
    /// reset the second phase would start at 100% and count down.
    @Test func newPhaseResetsCountersButKeepsTasks() {
        var progress = PullProgress()
        progress.apply([
            .description("Fetching image"), .itemsName("blobs"),
            .setTotalTasks(2), .addTasks(1),
            .setTotalSize(1000), .setSize(1000),
            .setTotalItems(5), .setItems(5),
        ])
        #expect(progress.fraction == 1)

        progress.apply([.description("Unpacking image"), .itemsName("entries")])

        #expect(progress.description == "Unpacking image")
        #expect(progress.itemsName == "entries")
        #expect(progress.fraction == nil, "the new phase has not reported its totals yet")
        #expect(progress.bytes == 0)
        #expect(progress.items == 0)
        #expect(progress.tasks == 1, "task progress spans both phases and must survive")
        #expect(progress.totalTasks == 2)
    }

    @Test func summariesReadNaturally() {
        var progress = PullProgress()
        progress.apply([.itemsName("blobs"), .setTotalItems(7), .setItems(3)])
        #expect(progress.itemsSummary == "3 of 7 blobs")

        progress.apply([.setTotalSize(41_200_000), .setSize(12_400_000)])
        #expect(progress.bytesSummary?.contains("of") == true)
    }

    @Test func itemsSummaryWithoutATotalStillSaysSomething() {
        var progress = PullProgress()
        progress.apply([.itemsName("entries"), .addItems(12)])
        #expect(progress.itemsSummary == "12 entries")
    }
}

@MainActor
@Suite struct PullJobTests {

    @Test func successfulPullFinishesAndRefreshesTheList() async {
        let backend = MockBackend(images: [])
        let store = ImageStore(backend: backend)
        backend.setPullProgress([
            { var p = PullProgress(); p.apply([.description("Fetching image"), .setTotalSize(100), .setSize(50)]); return p }(),
            { var p = PullProgress(); p.apply([.description("Fetching image"), .setTotalSize(100), .setSize(100)]); return p }(),
        ])

        let job = store.pull(reference: "alpine:3.20")
        await store.settlePulls()

        #expect(job.state == .succeeded)
        #expect(job.progress.fraction == 1)
        #expect(backend.calls.pull == 1)
        #expect(backend.calls.listImages >= 1, "a finished pull must refresh the list")
    }

    @Test func failedPullKeepsTheErrorVisible() async {
        let backend = MockBackend()
        backend.setPullFailure(.upstream(code: "notFound", message: "image not found"))
        let store = ImageStore(backend: backend)

        let job = store.pull(reference: "nope:latest")
        await store.settlePulls()

        #expect(job.state == .failed(.upstream(code: "notFound", message: "image not found")))
        #expect(store.pulls.contains { $0.id == job.id }, "a failure must not vanish silently")
    }

    @Test func jobAppearsImmediatelySoTheClickRegisters() {
        let store = ImageStore(backend: MockBackend())
        let job = store.pull(reference: "alpine")

        #expect(store.activePulls.map(\.id) == [job.id])
        job.cancel()
    }

    @Test func dismissRemovesAFinishedJob() async {
        let backend = MockBackend()
        backend.setPullFailure(.other("boom"))
        let store = ImageStore(backend: backend)

        let job = store.pull(reference: "alpine")
        await store.settlePulls()
        store.dismiss(job)

        #expect(store.pulls.isEmpty)
    }

    /// Cancelling an `AsyncThrowingStream` consumer makes the stream *finish*
    /// rather than throw, so without an explicit check a cancelled pull reports
    /// success for an image that was never fetched. Observed against a real
    /// 3.4 GB pull cancelled at 57 MB.
    @Test func cancelledPullIsNotReportedAsSuccess() async {
        let backend = MockBackend()
        backend.setPullProgress(Array(repeating: PullProgress(), count: 200))
        let store = ImageStore(backend: backend)

        let job = store.pull(reference: "python:3.12")
        try? await Task.sleep(for: .milliseconds(30))
        job.cancel()
        await store.settlePulls()

        #expect(job.state == .cancelled)
        #expect(job.state != .succeeded, "a cancelled pull must never claim to have succeeded")
    }

    @Test func twoPullsRunIndependently() async {
        let backend = MockBackend()
        let store = ImageStore(backend: backend)

        let first = store.pull(reference: "alpine")
        let second = store.pull(reference: "nginx")
        #expect(store.activePulls.count == 2)

        await store.settlePulls()

        #expect(first.state == .succeeded)
        #expect(second.state == .succeeded)
        #expect(backend.calls.pull == 2)
    }
}
