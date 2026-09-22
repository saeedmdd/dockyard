import Dispatch
import Foundation

/// Follows a container log file and emits lines as they are written.
///
/// Container logs are ordinary files on disk that the runtime appends to, so
/// following one means `tail -f`, not reading a pipe. Two consequences shape
/// this type:
///
/// * **Checked on a timer, not woken per write.** Neither of the obvious
///   event-driven options works here. A `readabilityHandler` on a regular file
///   reports ready even at end-of-file, so it spins. A `DispatchSource` vnode
///   watch fires once per *write*, and a container logging in a loop writes
///   hundreds of thousands of times a second: measured on such a container it
///   produced ~2 million context switches and pinned the app at ~120% CPU with
///   a handler that did nothing but set a flag. Checking the file's length on
///   the same timer that delivers lines costs four `lseek`s a second whether
///   the container is silent or screaming.
/// * **Truncation is normal.** Restarting a container gives it a fresh log, and
///   the file shrinks under the reader. That is reported rather than producing
///   garbage from a stale offset.
public final class LogTailer: @unchecked Sendable {
    /// Lines are delivered in batches: a container can emit thousands per
    /// second, and waking the UI for each one would stall it.
    /// 4 updates a second. Faster looks identical to a reader — nobody follows
    /// thousands of lines a second — but costs AppKit a full window layout pass
    /// each time, which profiling showed dominating everything else.
    private static let batchInterval = DispatchTimeInterval.milliseconds(250)

    private let source: LogSource
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.saeedmdd.Dockyard.LogTailer")

    /// A single flush never carries more than this. A container logging in a
    /// loop writes hundreds of thousands of lines a second; building a value
    /// for each one costs more than the UI could ever display, so the excess is
    /// dropped here rather than further down the pipeline.
    private static let maxLinesPerFlush = 2_000

    /// The most text converted into lines per flush.
    ///
    /// A container logging in a loop writes tens of megabytes a second. Turning
    /// all of that into `String`s costs more CPU than the app has, and all but
    /// the last few thousand lines would be discarded anyway. Beyond this
    /// window the bytes are still scanned — cheaply, to count what was missed —
    /// but never decoded.
    private static let maxBytesPerParse = 256 * 1024

    private var flushTimer: DispatchSourceTimer?
    private var offset: UInt64 = 0
    /// Bytes read but not yet terminated by a newline.
    private var partialLine = Data()
    /// Lines read since the last flush.
    private var pending: [String] = []
    /// Lines discarded because they arrived faster than they could be shown.
    private var droppedSinceFlush = 0
    private var continuation: AsyncStream<LogEvent>.Continuation?

    public init(handle: FileHandle, source: LogSource) {
        self.handle = handle
        self.source = source
    }

    /// Emits everything already in the file, then every line written after.
    ///
    /// - Parameter tailLines: when set, only the last N existing lines are
    ///   emitted. A container that has been running for days can have a log far
    ///   larger than anyone wants rendered.
    public func stream(tailLines: Int? = nil) -> AsyncStream<LogEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            queue.async { [weak self] in
                self?.readExisting(tailLines: tailLines)
                self?.startFlushing()
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    /// Stops watching and releases the file.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            flushTimer?.cancel()
            flushTimer = nil
            flush()
            continuation?.finish()
            continuation = nil
        }
    }

    /// One timer drives everything: it checks the file for new bytes and
    /// delivers whatever it found. Reading and delivering on the same tick is
    /// what keeps a screaming container from waking the process continuously.
    private func startFlushing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.batchInterval, repeating: Self.batchInterval)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        flushTimer = timer
        timer.resume()
    }

    private func flush() {
        readNewData()
        guard !pending.isEmpty || droppedSinceFlush > 0 else { return }
        if pending.isEmpty {
            continuation?.yield(.dropped(droppedSinceFlush))
            droppedSinceFlush = 0
            return
        }
        let batch = pending
        let dropped = droppedSinceFlush
        pending.removeAll(keepingCapacity: true)
        droppedSinceFlush = 0
        if dropped > 0 {
            continuation?.yield(.dropped(dropped))
        }
        continuation?.yield(.lines(batch.map { LogLine(id: 0, source: source, text: $0) }))
    }

    // MARK: - Reading

    private func readExisting(tailLines: Int?) {
        guard let size = try? handle.seekToEnd() else { return }
        offset = size
        guard size > 0 else { return }

        let existing: [String]
        if let tailLines {
            existing = splitIntoLines(readTail(lines: tailLines, fileSize: size), keepingPartial: false)
        } else {
            try? handle.seek(toOffset: 0)
            let data = (try? handle.readToEnd()) ?? Data()
            existing = splitIntoLines(String(decoding: data, as: UTF8.self), keepingPartial: false)
        }
        // Delivered directly rather than queued: the backlog is deliberately
        // sized to fill the buffer, and the per-flush cap would truncate it.
        if !existing.isEmpty {
            continuation?.yield(.lines(existing.map { LogLine(id: 0, source: source, text: $0) }))
        }
        try? handle.seek(toOffset: size)
    }

    /// Reads backwards in chunks until `lines` newlines have been seen, so a
    /// 500 MB log costs a few kilobytes of reading rather than all of it.
    private func readTail(lines: Int, fileSize: UInt64) -> String {
        let chunkSize: UInt64 = 64 * 1024
        var collected = Data()
        var position = fileSize
        var newlines = 0

        while position > 0 && newlines <= lines {
            let readSize = min(chunkSize, position)
            position -= readSize
            try? handle.seek(toOffset: position)
            guard let chunk = try? handle.read(upToCount: Int(readSize)), !chunk.isEmpty else { break }
            newlines += chunk.count { $0 == UInt8(ascii: "\n") }
            collected = chunk + collected
        }

        let text = String(decoding: collected, as: UTF8.self)
        let allLines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        return allLines.suffix(lines).joined(separator: "\n")
    }

    private func readNewData() {
        guard let size = try? handle.seekToEnd() else { return }

        if size < offset {
            // The container restarted and the runtime replaced the log.
            // Re-reading from the top is what a user expects to see.
            continuation?.yield(.truncated)
            offset = 0
            partialLine.removeAll()
        }
        guard size > offset else { return }

        var skippedPartialLine = false
        if size - offset > UInt64(Self.maxBytesPerParse) {
            // Too far behind to decode it all. Count what is being skipped by
            // scanning bytes — cheap next to building a String per line — then
            // resume from the tail of the backlog.
            let resumeAt = size - UInt64(Self.maxBytesPerParse)
            droppedSinceFlush += countNewlines(from: offset, to: resumeAt)
            offset = resumeAt
            partialLine.removeAll()
            skippedPartialLine = true
        }

        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(size - offset))) ?? Data()
        offset = size
        guard !data.isEmpty else { return }

        var text = String(decoding: partialLine + data, as: UTF8.self)
        if skippedPartialLine {
            // The window almost certainly opens mid-line; that fragment is not
            // a line and would be misleading on its own.
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
                droppedSinceFlush += 1
            }
        }
        emit(splitIntoLines(text, keepingPartial: true))
    }

    /// Counts newlines in a byte range without decoding it, so a backlog can be
    /// accounted for without paying to turn it into text.
    private func countNewlines(from start: UInt64, to end: UInt64) -> Int {
        guard end > start else { return 0 }
        let chunkSize = 1 << 20
        var position = start
        var count = 0
        try? handle.seek(toOffset: position)
        while position < end {
            let wanted = Int(min(UInt64(chunkSize), end - position))
            guard let chunk = try? handle.read(upToCount: wanted), !chunk.isEmpty else { break }
            // Scanned through the raw buffer rather than with `count(where:)`:
            // that goes through `Data.Iterator`, which dispatches per byte and
            // dominated a profile of this exact path at ~85% of the tailer's
            // time. Here the loop is over plain bytes.
            count += chunk.withUnsafeBytes { raw in
                var found = 0
                for byte in raw where byte == UInt8(ascii: "\n") { found += 1 }
                return found
            }
            position += UInt64(chunk.count)
        }
        return count
    }

    /// Splits text into complete lines, holding back a trailing fragment until
    /// the newline that finishes it arrives — a line written in two writes must
    /// not appear as two lines.
    private func splitIntoLines(_ text: String, keepingPartial: Bool) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if keepingPartial {
            let trailing = parts.removeLast()
            partialLine = Data(trailing.utf8)
        } else {
            partialLine.removeAll()
            if parts.last?.isEmpty == true { parts.removeLast() }
        }
        return parts
    }

    /// Queues lines for the next flush, keeping only the most recent when they
    /// arrive faster than they can be shown.
    private func emit(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        pending.append(contentsOf: texts)
        let excess = pending.count - Self.maxLinesPerFlush
        if excess > 0 {
            pending.removeFirst(excess)
            droppedSinceFlush += excess
        }
    }
}
