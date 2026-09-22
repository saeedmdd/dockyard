import Foundation
import Testing

@testable import DockyardCore

@MainActor
@Suite struct PollerTests {

    /// Counts ticks without relying on wall-clock timing for correctness.
    private final class Counter {
        var value = 0
    }

    @Test func startsInactiveAndTicksNothing() {
        let counter = Counter()
        let poller = Poller(interval: .milliseconds(10)) { counter.value += 1 }

        #expect(!poller.isActive)
        #expect(counter.value == 0)
        poller.pause()
    }

    /// Reopening a window must show current data, not wait out an interval.
    @Test func resumeRefreshesImmediately() async {
        let counter = Counter()
        let poller = Poller(interval: .seconds(30)) { counter.value += 1 }

        poller.resume()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(poller.isActive)
        #expect(counter.value == 1, "first tick must not wait for the interval")
        poller.pause()
    }

    @Test func pauseStopsTicking() async {
        let counter = Counter()
        let poller = Poller(interval: .milliseconds(30)) { counter.value += 1 }

        poller.resume()
        try? await Task.sleep(for: .milliseconds(200))
        poller.pause()
        let afterPause = counter.value

        try? await Task.sleep(for: .milliseconds(200))

        #expect(!poller.isActive)
        #expect(counter.value == afterPause, "no ticks after pause")
        #expect(afterPause > 1, "should have ticked several times while active")
    }

    @Test func resumeAfterPauseResumesTicking() async {
        let counter = Counter()
        let poller = Poller(interval: .milliseconds(30)) { counter.value += 1 }

        poller.resume()
        try? await Task.sleep(for: .milliseconds(100))
        poller.pause()
        let afterPause = counter.value

        poller.resume()
        try? await Task.sleep(for: .milliseconds(150))
        poller.pause()

        #expect(counter.value > afterPause)
    }

    /// ⌘R must refresh now, whether or not the loop is running.
    @Test func tickNowWorksWhilePaused() async {
        let counter = Counter()
        let poller = Poller(interval: .seconds(30)) { counter.value += 1 }

        await poller.tickNow()

        #expect(counter.value == 1)
        #expect(!poller.isActive, "an explicit refresh must not start the loop")
    }

    @Test func resumeTwiceDoesNotRunTwoLoops() async {
        let counter = Counter()
        let poller = Poller(interval: .milliseconds(40)) { counter.value += 1 }

        poller.resume()
        poller.resume()
        try? await Task.sleep(for: .milliseconds(250))
        poller.pause()

        // Two concurrent loops would roughly double this.
        #expect(counter.value <= 8, "got \(counter.value) ticks, suggesting more than one loop")
    }

    /// A slow refresh must space itself out rather than queue up.
    @Test func slowTicksDoNotOverlap() async {
        let counter = Counter()
        let inFlight = Counter()
        let overlaps = Counter()
        let poller = Poller(interval: .milliseconds(10)) {
            inFlight.value += 1
            if inFlight.value > 1 { overlaps.value += 1 }
            try? await Task.sleep(for: .milliseconds(60))
            inFlight.value -= 1
            counter.value += 1
        }

        poller.resume()
        try? await Task.sleep(for: .milliseconds(300))
        poller.pause()

        #expect(overlaps.value == 0, "ticks overlapped")
        #expect(counter.value > 0)
    }

    @Test func changingIntervalWhileActiveTakesEffect() async {
        let counter = Counter()
        let poller = Poller(interval: .seconds(30)) { counter.value += 1 }

        poller.resume()
        try? await Task.sleep(for: .milliseconds(80))
        let beforeChange = counter.value

        poller.interval = .milliseconds(30)
        try? await Task.sleep(for: .milliseconds(200))
        poller.pause()

        #expect(counter.value > beforeChange + 1, "shortened interval should not wait out the old sleep")
    }
}
