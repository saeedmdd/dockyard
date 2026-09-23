# T18 — System panel: df, prune, versions, logs

**Milestone:** M4 · **Depends on:** T03 · **Status:** done

## Upstream references
- `Sources/Services/ContainerAPIService/Client/ClientDiskUsage.swift` + `DiskUsage.swift` — `DiskUsageStats` (images/containers/volumes counts, sizes, reclaimable).
- `ClientImage.cleanUpOrphanedBlobs()`, `calculateDiskUsage(activeReferences:)`.
- `Sources/ContainerCommands/System/SystemDF.swift`, `SystemLogs.swift` (log root from `SystemHealth.logRoot`), `SystemVersion.swift`, `SystemProperty.swift`, `SystemKernel.swift`.
- `ClientKernel.swift` — default kernel info.
- `ContainerCommands/{Container/ContainerPrune,Image/ImagePrune,Volume/VolumePrune}.swift` — the three sweeps and what each counts as "in use".

## Files
- `Models/DiskUsage.swift` — `ResourceUsage`, `DiskUsage`, `PruneTarget`, `PruneResult`, `KernelInfo`.
- `Backend/ContainerBackend.swift` — `diskUsage()`, `prune(_:)`, `kernelInfo()`.
- `Backend/CLIRunner.swift` — `systemLogs(last:)` and `SystemLogWindow`.
- `Stores/SystemStore.swift` — `diskUsage`, `kernel`, `prune`, `loadLogs`, `panelError`.
- `Dockyard/System/SystemView.swift` — Status, Versions, Disk usage, Kernel, Logs, Files.
- `Dockyard/Components/PlainTextLogView.swift`.

## Acceptance
- [x] Numbers match `container system df` — compared against the CLI in an integration test and
      again in the running app: Images 11/4 · 9.34 GB · 3.07 GB, Containers 6/0 · 5.06 GB, Volumes
      0/0, identical in both.
- [x] Prune removes only what is unused and reports what it reclaimed — verified end to end in the
      app on a throwaway volume: confirmation, "Removed 1 volume, reclaimed 69.4 MB", numbers
      re-read, and the CLI agreeing the volume was gone. The container and image sweeps are covered
      against the mock and by gated integration tests (see below).
- [x] Prune is refused when there is nothing idle: with no volumes the button is disabled and reads
      "Everything here is in use".
- [x] Stop from the panel → onboarding with streamed output → Start → lists refill. Verified twice;
      the first time it found the bug below.
- [x] Logs match `container system logs`: one header line for a quiet 5 minutes, and the same 562
      lines over a day.
- [x] 285 unit tests in 43 suites, 56 integration tests; `xcodebuild` clean.
- [x] No leftovers: 6 containers, 9 images, 0 volumes, exactly as before.

## Findings

- **A stale XPC client made the Containers screen lie.** Stopping and starting the daemon from the
  panel left the app showing "No containers yet" while the CLI listed six, and only relaunching
  fixed it. `ContainerClient` holds a reusable XPC connection; the CLI makes one per command and
  exits, so upstream never meets this. Worse than an error: a client made before the restart answered
  `list` with an **empty array**, which every layer above it faithfully rendered as "nothing here".
  Images and volumes were unaffected because upstream exposes those as statics that build a client
  per call. `LiveBackend` now does the same, and a gated integration test restarts the daemon and
  asserts the backend still sees what it saw before. Found only because the acceptance list said to
  stop and start from the panel rather than to trust that the store refreshes.
- **`container system logs` does not read a log folder.** It shells out to
  `log show --predicate "subsystem = 'com.apple.container'"`, and `SystemHealth.logRoot` is empty on
  a normal install — so the planned "open the log folder in Finder" button would have opened nothing.
  The panel reads the unified log through the CLI instead, with a window picker, and says so, because
  people go looking for a file. The folder row appears only when `logRoot` is actually set.
- **Upstream's `image prune --all` deletes the runtime's own images.** It filters by "no container
  refers to it", which is true of the builder and vminit images, so a prune leaves the next build to
  re-pull them. Dockyard excludes infrastructure images, the same exclusion the delete path already
  makes.
- **Rendering the log as SwiftUI `Text` views was untenable.** A day's output is hundreds of lines
  and the cap is 2,000; stacking that many views made the window's accessibility tree large enough
  that a walk of it timed out. `PlainTextLogView` holds it in one `NSTextView`, the same reasoning as
  `LogTextView` in T07 without the tailing.
- **"Zero kB" again, for the fourth time.** `ByteCountFormatStyle` spells out zero by default. The
  formatting now lives on the model as `DiskUsage.label(_:)` so the next byte count cannot forget it.
- The panel keeps its last numbers when the daemon goes away mid-query rather than blanking: the
  status section immediately above already says why they are not moving.
- The prune result is kept on screen with its reason rather than folded into an error, so a sweep
  that removed four of five can say which one it could not take.
- A prune that untags images whose layers are still shared reclaims nothing; the summary says so
  instead of printing "reclaimed 0 bytes".

## Not run here: the container and image sweeps
`prune(.containers)` takes every stopped container and `prune(.images)` every unreferenced image.
This machine holds six stopped containers someone is working with, so running either to satisfy a
test would destroy real data. Both are covered against the mock, share their selection rule with the
volume sweep that *is* run against the real runtime, and have integration tests held behind
`DOCKYARD_DESTRUCTIVE=1` for a throwaway machine. The daemon-restart test is behind the same flag,
since stopping the container system stops everything running in it.

## Notes
The `container system df` parity test brackets the app's reading between two CLI readings and accepts
a match with either. The other suites run in parallel and create and delete containers throughout,
and each `container system df` is a process launch, so a single reading against a single reading
disagreed most runs — a race in the test, not a difference worth failing over. A genuinely wrong
number matches neither end.
