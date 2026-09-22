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
- [ ] `container run -d --name spam alpine sh -c 'i=0; while true; do echo line $i; i=$((i+1)); done'` → Logs tab scrolls smoothly, CPU of Dockyard < 15% on M-series, no beachball.
- [ ] Pause stops scrolling; resume jumps to bottom.
- [ ] Boot log toggle shows the VM boot output.
- [ ] Search highlights and jumps between matches.
- [ ] Switching containers stops the previous tailer (no leaked FileHandles: check with `lsof -p`).

## Notes
