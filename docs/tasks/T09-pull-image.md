# T09 — Pull sheet with progress

**Milestone:** M2 · **Depends on:** T04 · **Status:** todo

## Goal
Pull an image by reference with per-layer progress and cancellation.

## Upstream references
- `Sources/Services/ContainerAPIService/Client/ClientImage.swift` — `static pull(reference:platform:scheme:containerSystemConfig:progressUpdate:maxConcurrentDownloads:) -> ClientImage`; `normalizeReference`.
- `Sources/Services/ContainerAPIService/Client/ProgressUpdateClient.swift`, `ContainerizationProgressAdapter.swift` — `ProgressUpdateHandler` event shape (items/sizes/subtasks).
- `Sources/ContainerCommands/Image/ImagePull.swift` — how the CLI wires `ProgressBar` + `TaskManager`; note it also **unpacks** after pull (`image.unpack(platform:)`) — replicate so the image is runnable.

## Files
- `Models/PullProgress.swift` — `phase (.resolving/.downloading/.unpacking/.done), layers: [LayerProgress{digest, done, total}], overall`.
- `Backend/ContainerBackend.swift` — `pullImage(reference:platform:) -> AsyncThrowingStream<PullProgress, Error>`.
- `Backend/LiveBackend.swift` — adapt `ProgressUpdateHandler` events to `PullProgress`; unpack after pull; honour `Task.cancel()`.
- `Stores/ImageStore.swift` — `pulls: [PullJob]` (id, reference, progress, task), `pull(reference:platform:)`, `cancel(_:)`.
- `Dockyard/Images/PullSheet.swift` — reference text field (recent refs in `UserDefaults`), platform picker (default host: `linux/arm64`), Pull button.
- `Dockyard/Images/PullProgressRow.swift` — shows in Images list top area while active; cancel button.
- `Tests/DockyardCoreTests/ImageStoreTests.swift` — job lifecycle with MockBackend stream.

## Acceptance
- [x] Pulled `busybox:1.36` from the sheet. Progress advanced through real values —
      `Fetching image · 2.2 MB of 17.3 MB · 23 of 52 blobs` — ending at "Pulled and unpacked". The
      images list refreshed itself from "9 shown" to "10 shown" and `container image list` agreed.
- [x] Cancelled a 3.4 GB `python:3.12` pull mid-flight → row reads "Cancelled", and the image is
      absent from `container image list`. **This is where the bug below was found.**
- [x] Two pulls shown and tracked independently (a finished `busybox` row beside a running
      `python:3.12` row).
- [x] 144 unit tests in 22 suites, 8 integration tests; `xcodebuild` clean.

## Findings
- **Bug found by testing cancellation against a real pull: a cancelled pull reported success.**
  Cancelling the consuming task makes an `AsyncThrowingStream` *finish* rather than throw, so the
  `for try await` loop exited normally and the job was marked "Pulled and unpacked" — for a 3.4 GB
  image that had reached 57 MB and was never fetched. A `Task.checkCancellation()` after the loop
  fixes it, and a regression test covers it. A mock-only test would not have caught this, because
  the mistake was in believing what cancellation does to a stream.
- **The runtime never names the phase.** `container image pull` sets "Fetching image" / "Unpacking
  image" and the item names "blobs" / "entries" on *its own* progress bar; they are not events from
  the server. Without doing the same, every pull read "Starting…" from beginning to end — which is
  exactly what the first run showed. The backend now sets the phase around each stage.
- **Unpacking is part of pulling.** `ClientImage.pull` only fetches; the CLI follows it with
  `image.unpack`. Skipping that would put a row in the list that fails the moment it is run.
- **Deviation from the plan:** the plan called for "per-layer progress rows". The runtime does not
  expose per-layer data — `ProgressUpdateEvent` carries running totals of tasks, items and bytes.
  The UI shows those aggregates, which is everything there is.
- `.byteCount` spells out zero by default, so a pull's first moment read "Zero kB of 17.3 MB". Same
  trap as T08, in a different file; fixed here too.
- The progress fraction prefers bytes over item counts (bytes move smoothly) and is `nil` until the
  runtime reports a total, so the bar is indeterminate rather than lying.

## Notes
