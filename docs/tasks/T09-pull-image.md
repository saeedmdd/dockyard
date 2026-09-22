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
- [ ] Pull `docker.io/library/alpine:3.20` → layer bars advance → image appears in list, `container image list` agrees.
- [ ] Cancel mid-pull → job removed, no partial image row, no crash.
- [ ] Bad reference → error toast with upstream message.
- [ ] Two concurrent pulls both progress.

## Notes
