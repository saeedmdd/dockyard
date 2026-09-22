import Foundation
import Testing

@testable import DockyardCore

@Suite struct LogBufferTests {

    @Test func appendAssignsSequentialIDs() {
        var buffer = LogBuffer()
        buffer.append(["one", "two"], source: .stdio)
        buffer.append(["three"], source: .stdio)

        #expect(buffer.lines.map(\.id) == [0, 1, 2])
        #expect(buffer.lines.map(\.text) == ["one", "two", "three"])
    }

    /// A container logging in a loop must not grow the app's memory forever.
    @Test func oldestLinesAreDroppedAtCapacity() {
        var buffer = LogBuffer(capacity: 3)
        buffer.append(["a", "b", "c", "d", "e"], source: .stdio)

        #expect(buffer.lines.map(\.text) == ["c", "d", "e"])
        #expect(buffer.droppedCount == 2)
        #expect(buffer.count == 3)
    }

    @Test func droppedCountAccumulatesAcrossAppends() {
        var buffer = LogBuffer(capacity: 2)
        buffer.append(["a", "b", "c"], source: .stdio)
        buffer.append(["d", "e"], source: .stdio)

        #expect(buffer.droppedCount == 3)
        #expect(buffer.lines.map(\.text) == ["d", "e"])
    }

    /// Ids must stay unique across a clear, or a list would see duplicates.
    @Test func idsKeepCountingAfterClear() {
        var buffer = LogBuffer()
        buffer.append(["a", "b"], source: .stdio)
        buffer.removeAll()
        buffer.append(["c"], source: .stdio)

        #expect(buffer.lines.map(\.id) == [2])
    }

    @Test func searchIsCaseInsensitiveAndReturnsIndices() {
        var buffer = LogBuffer()
        buffer.append(["Error: failed", "ok", "another ERROR"], source: .stdio)

        #expect(buffer.search("error") == [0, 2])
        #expect(buffer.search("") == [])
        #expect(buffer.search("nothing") == [])
    }

    @Test func appendingNothingChangesNothing() {
        var buffer = LogBuffer()
        buffer.append([], source: .stdio)
        #expect(buffer.isEmpty)
        #expect(buffer.totalCount == 0)
    }

    @Test func capacityIsAtLeastOne() {
        var buffer = LogBuffer(capacity: 0)
        buffer.append(["only"], source: .stdio)
        #expect(buffer.count == 1)
    }

    /// A batch bigger than the buffer must not be built line by line only to be
    /// thrown away; the surplus is accounted for as dropped.
    @Test func batchLargerThanCapacityKeepsOnlyTheTail() {
        var buffer = LogBuffer(capacity: 3)
        buffer.append((1...1000).map { "line \($0)" }, source: .stdio)

        #expect(buffer.lines.map(\.text) == ["line 998", "line 999", "line 1000"])
        #expect(buffer.droppedCount == 997)
        // Ids stay aligned with the real position in the stream.
        #expect(buffer.lines.map(\.id) == [997, 998, 999])
    }

    @Test func droppedLinesFromTheTailerAreCounted() {
        var buffer = LogBuffer(capacity: 10)
        buffer.append(["a"], source: .stdio)
        buffer.recordDropped(50)
        buffer.append(["b"], source: .stdio)

        #expect(buffer.droppedCount == 50)
        #expect(buffer.lines.map(\.text) == ["a", "b"])
        #expect(buffer.lines.last?.id == 51, "ids must account for the gap")
    }
}

/// Exercised against real files on disk, because that is what container logs
/// are: the runtime appends to a regular file that can also be truncated.
@Suite struct LogTailerTests {

    private func makeFile(_ contents: String = "") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dockyard-log-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Collects events until `count` lines have arrived or the deadline passes.
    private func collect(
        from tailer: LogTailer,
        tailLines: Int? = nil,
        untilLines count: Int,
        timeout: Duration = .seconds(5),
        perform: @escaping @Sendable () async -> Void = {}
    ) async -> [LogEvent] {
        let stream = tailer.stream(tailLines: tailLines)
        let writer = Task { await perform() }
        // Ends the stream if the expected lines never arrive, so a broken
        // tailer fails the test instead of hanging it.
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            tailer.stop()
        }

        // Iterated in the caller's isolation so the accumulators stay local.
        var events: [LogEvent] = []
        var lineCount = 0
        for await event in stream {
            events.append(event)
            if case .lines(let lines) = event { lineCount += lines.count }
            if lineCount >= count { break }
        }

        deadline.cancel()
        await writer.value
        tailer.stop()
        return events
    }

    private func lines(in events: [LogEvent]) -> [String] {
        events.flatMap { event -> [String] in
            if case .lines(let lines) = event { return lines.map(\.text) }
            return []
        }
    }

    @Test func existingContentIsEmittedOnStart() async throws {
        let url = try makeFile("first\nsecond\nthird\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, untilLines: 3)

        #expect(lines(in: events) == ["first", "second", "third"])
    }

    /// The point of the whole type: lines written after opening must arrive.
    @Test func linesWrittenAfterOpeningArrive() async throws {
        let url = try makeFile("existing\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, untilLines: 3) {
            try? await Task.sleep(for: .milliseconds(300))
            let writer = try? FileHandle(forWritingTo: url)
            _ = try? writer?.seekToEnd()
            try? writer?.write(contentsOf: Data("live one\nlive two\n".utf8))
            try? writer?.close()
        }

        #expect(lines(in: events) == ["existing", "live one", "live two"])
    }

    /// A line split across two writes must not appear as two lines.
    @Test func lineSplitAcrossWritesIsReassembled() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, untilLines: 1) {
            let writer = try? FileHandle(forWritingTo: url)
            try? await Task.sleep(for: .milliseconds(250))
            try? writer?.write(contentsOf: Data("half a ".utf8))
            try? await Task.sleep(for: .milliseconds(250))
            try? writer?.write(contentsOf: Data("line\n".utf8))
            try? writer?.close()
        }

        #expect(lines(in: events) == ["half a line"])
    }

    /// Restarting a container gives it a fresh log; the file shrinks under us.
    @Test func truncationIsReportedRatherThanProducingGarbage() async throws {
        let url = try makeFile("old line one\nold line two\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, untilLines: 3) {
            try? await Task.sleep(for: .milliseconds(300))
            // Replace the contents with something shorter.
            try? "fresh\n".write(to: url, atomically: false, encoding: .utf8)
        }

        #expect(events.contains(.truncated), "a shrinking file must be reported")
        #expect(lines(in: events).contains("fresh"))
    }

    /// A long-running container's log can be huge; only the tail is rendered.
    @Test func tailLinesReadsOnlyTheEnd() async throws {
        let many = (1...5000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let url = try makeFile(many)
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, tailLines: 10, untilLines: 10)
        let texts = lines(in: events)

        #expect(texts.count == 10)
        #expect(texts.first == "line 4991")
        #expect(texts.last == "line 5000")
    }

    @Test func emptyFileProducesNoLines() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, untilLines: 1, timeout: .milliseconds(600))

        #expect(lines(in: events).isEmpty)
    }

    /// Lines are delivered on a timer, so a container writing continuously
    /// wakes the UI a handful of times a second rather than thousands.
    @Test func continuousWritesAreDeliveredInBatches() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, untilLines: 400, timeout: .seconds(4)) {
            let writer = try? FileHandle(forWritingTo: url)
            // 400 lines written one at a time: without batching this would be
            // 400 separate deliveries.
            for i in 1...400 {
                try? writer?.write(contentsOf: Data("line \(i)\n".utf8))
                if i % 50 == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            }
            try? writer?.close()
        }

        let batches = events.filter { if case .lines = $0 { return true } else { return false } }
        #expect(lines(in: events).count >= 400)
        #expect(batches.count < 60, "expected batching, got \(batches.count) deliveries for 400 lines")
    }

    /// A line far longer than one read must stay one line.
    @Test func veryLongLineIsNotSplit() async throws {
        let long = String(repeating: "x", count: 300_000)
        let url = try makeFile(long + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = LogTailer(handle: try FileHandle(forReadingFrom: url), source: .stdio)

        let events = await collect(from: tailer, untilLines: 1)
        let texts = lines(in: events)

        #expect(texts.count == 1)
        #expect(texts.first?.count == 300_000)
    }
}
