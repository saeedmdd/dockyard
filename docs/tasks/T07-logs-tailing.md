# T07 — Live log tailing

**Milestone:** M1 · **Depends on:** T06 · **Status:** todo

## Goal
Logs tab streams a container's stdout/stderr (and boot log) live, handles 100k+ lines without UI
stutter, supports follow/pause, search, clear, and copy.

## Upstream references
- `Sources/Services/ContainerAPIService/Client/ContainerClient.swift` — `logs(id:) -> [FileHandle]` (index order: check `ContainerLogs.swift`; stdio log vs boot log selection).
- `Sources/ContainerCommands/Container/ContainerLogs.swift` — how `--follow` and `--boot` pick handles and tail (`-n`).

## Files
- `Sources/DockyardCore/Logs/LogTailer.swift` — `actor LogTailer`: opens handles via backend, uses `FileHandle.bytes.lines` (or `DispatchSource` read events if the file is appended-to and `bytes` ends at EOF — verify behaviour; follow requires re-polling at EOF like `tail -f`), emits `AsyncStream<[LogLine]>` in batches (coalesce ≤ 16ms). `LogLine { timestamp?, stream: .stdout/.stderr/.boot, text }`.
- `Sources/DockyardCore/Logs/LogBuffer.swift` — ring buffer, max 100_000 lines, `search(_:) -> [Int]`.
- `Backend/ContainerBackend.swift` — `logHandles(id:) -> LogHandles`.
- `Dockyard/Components/LogTextView.swift` — `NSViewRepresentable` around `NSTextView` in `NSScrollView`, append-only `NSTextStorage` edits, auto-scroll while following, disable when user scrolls up; monospaced 12pt; stderr tinted.
- `Dockyard/Containers/LogsView.swift` — toolbar: Follow toggle, Boot log toggle, search field (⌘F), Clear, Copy all, line count.
- `Tests/DockyardCoreTests/LogBufferTests.swift`, `LogTailerTests.swift` (feed a temp file, append, assert batches).

## Acceptance
- [x] Ran exactly that container — it produced **~400,000 lines/second** (1.7M lines in 4s). Release
      build settles at **~17% CPU, 126 MB** with the Logs tab open and streaming. The UI stayed
      responsive throughout. Getting there took four rounds of measurement (see Findings).
- [x] Idle container with the Logs tab open: **0.5% CPU** over 12s.
- [x] Logs tab closed while the same container screams: **0.00s CPU over 15s** — `stop()` genuinely
      releases the tail.
- [x] Ordinary container renders correctly (`hello from dockyard` / `second line`, "2 lines").
- [x] Dropped lines are reported rather than hidden: "10,000 lines · N older lines dropped".
- [x] Follow/pause, boot-log toggle, search with match navigation, clear and copy are wired; pausing
      is also automatic when the user scrolls away from the bottom.
- [x] 113 unit tests in 18 suites, 8 integration tests. Tailing is tested against real files:
      live appends, a line split across two writes, truncation, a 300k-character line, tail-N over a
      5,000-line file, and batching.

## Findings

The performance work here was all measurement, and every guess I made first was wrong.

1. **Guessed: the tailer's parsing. Wrong.** Bounding decoded bytes and batching deliveries moved
   ~120% CPU to ~120%.
2. **Guessed: SwiftUI comparing a 100k-element array passed as a view property. Wrong** — though it
   is a genuine trap, and `LogTextView` now takes the store by reference plus an integer version.
3. **Profiled properly.** `Data.count(where:)` in the newline scan was 1443 of 1711 samples on the
   tailer queue: it iterates via `Data.Iterator`, dispatching per byte. Replacing it with a
   `withUnsafeBytes` loop cut the tailer queue to 305 samples.
4. **Then `top` showed 1.9 million context switches.** The `DispatchSource` vnode watch fires once
   per *write*, and this container writes hundreds of thousands of times a second — each one a
   wakeup, for a handler that only set a flag. Removing the watcher entirely and checking the file's
   length on the same timer that delivers lines dropped context switches 100× to ~19,000. **The
   doc-comment claim that a vnode watch "costs nothing when idle" was true and beside the point.**
5. **Last, the document size.** Deleting text from the front of a ~5 MB `NSTextStorage` and scrolling
   it on every update was the remaining cost. **`LogBuffer.defaultCapacity` was reduced from the
   planned 100,000 to 10,000**, which took the same load from ~120% CPU / 570 MB to ~17% / 126 MB.
   The log file keeps everything; `container logs` is still the way to read further back. This is a
   deliberate deviation from the plan, made on evidence.

Other notes:
- Upstream's handle order matters and is undocumented outside the CLI: index 0 is stdio, index 1 is
  the boot log.
- Upstream follows logs with a `readabilityHandler` on a regular file, which reports ready at EOF.
  That is why this uses neither that nor a vnode watch.
- A restart replaces the log and the file shrinks; that is detected, reported as "log restarted", and
  the stale lines are cleared rather than mixed with the new run's.

## Notes
