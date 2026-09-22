# Dockyard — native macOS GUI for `apple/container`

> Execution: tasks live in [`tasks/INDEX.md`](tasks/INDEX.md) (T01–T20, one file each with upstream
> references and acceptance criteria). Each task is implemented following [`WORKFLOW.md`](WORKFLOW.md).

## Context

`apple/container` (CLI `container` v1.0.0 at `/usr/local/bin/container`) is Apple's Linux-container
runtime for macOS 26. It is CLI-only. Goal: a Docker Desktop / OrbStack style GUI — see images and
containers, pull/build images, run/start/stop containers — with **no runtime overhead** (no Electron,
no webview, no process-per-UI-tick).

Key finding: the upstream repo is a Swift package that exports the very XPC client libraries its CLI
uses (`ContainerAPIClient`, `ContainerImagesServiceClient`, `ContainerNetworkClient`, …). A Swift app
links them and talks to `container-apiserver` over XPC directly — the same path as the CLI, zero
process spawning, typed models, streaming progress. **Language: Swift 6 + SwiftUI/AppKit.**

Local observation: apiserver is "not running and not registered with launchd" on this machine → the
app must own the daemon-down and CLI-not-installed states as first-class screens.

## Decisions (from grilling session)

| # | Topic | Decision |
|---|---|---|
| 1 | Stack | Swift 6 + SwiftUI (AppKit where SwiftUI is weak: log view, terminal). Link `ContainerAPIClient` et al. over XPC. |
| 2 | Scope | Near CLI parity in v1, shipped in milestones (below). |
| 3 | Form factor | Main window (sidebar) + `MenuBarExtra` status item. App stays resident when window closed. |
| 4 | Upstream coupling | Pure frontend; requires Apple's official pkg. SPM dep pinned `exact: "1.0.0"`. Version-mismatch banner (`SystemHealth.apiServerVersion` vs linked version). |
| 5 | Freshness | No event API in 1.0.0 (verified). Poll ~2s while visible; immediate refetch after actions. Behind a protocol so events can replace it. |
| 6/8 | Build | Sheet (folder, Dockerfile auto-detect, tag, platform). v1 runs `container build` via `Process` and streams output; builder auto-start comes free. Port to `ContainerBuild` gRPC pipeline in v2. |
| 7 | Daemon ctl | Sanctioned `Process` shell-out #2: `container system start|stop`. It writes the launchd plist (`~/Library/Application Support/com.apple.container/apiserver/apiserver.plist`, mach service `com.apple.container.apiserver`) — not worth replicating. |
| 9 | Layout | `Dockyard.xcodeproj` app target + local SPM package `Packages/DockyardCore` (stores, backend, apple/container dep). Core is `swift build` / `swift test`-able. |
| 10 | Distribution | Non-sandboxed. Developer ID + notarize, GitHub Releases (+ Homebrew cask later). Ad-hoc signing during dev. |
| 11 | Run sheet | Full: maps 1:1 onto `Flags.Process/Management/Resource/DNS` and calls `Utility.containerConfigFromFlags` (same validation as CLI). |
| 12 | Logs / exec | Live-tailing logs (NSTextView-backed) **and** exec terminal via SwiftTerm. |
| 13 | Extras in v1 | Stats (Swift Charts), Volumes tab, Networks tab, Registry login + push/tag/save. |
| 14 | Name | **Dockyard**, bundle ID `com.saeedmdd.Dockyard`, core `DockyardCore`. |
| 15 | Testing | Unit tests on core with a mocked backend protocol **plus** env-gated integration tests against the real daemon (local only). |

## Prerequisites (blocking)

- **Xcode 26** — upstream `Package.swift` is `swift-tools-version: 6.2`; machine has Xcode 16.4 / Swift 6.1.2. Install Xcode 26 and `xcode-select` to it before step 1.
- apple/container 1.0.0 pkg installed (already true). Run `container system start` once to confirm the daemon works on this machine.

## Verified upstream API (apple/container 1.0.0 — source extracted in scratchpad `container-1.0.0/`)

Client targets are at `Sources/Services/*/Client`. Everything the app needs is public:

- **Containers** — `ContainerClient` (`Sources/Services/ContainerAPIService/Client/ContainerClient.swift`)
  `list(filters:) -> [ContainerSnapshot]`, `get(id:)`, `create(...)`, `bootstrap(id:stdio:dynamicEnv:) -> ClientProcess`, `stop(id:opts:)`, `kill(id:signal:)`, `delete(id:force:)`, `logs(id:) -> [FileHandle]`, `stats(id:) -> ContainerStats`, `diskUsage(id:)`, `createProcess(containerId:processId:configuration:stdio:[FileHandle?]) -> ClientProcess`, `dial(id:port:)`.
  `ContainerSnapshot { configuration, status: RuntimeStatus (.unknown/.stopped/.running/.stopping), networks, startedDate }`.
  Start = `get` → if `.stopped`: `ProcessIO.create(tty:interactive:detach:true)` → `bootstrap` → `process.start()` (mirror `ContainerCommands/Container/ContainerStart.swift:57-100`).
  `ClientProcess`: `start()`, `kill(_:)`, `resize(Terminal.Size)`, `wait() -> Int32`.
- **Run/create config** — `Utility.containerConfigFromFlags(id:image:arguments:process:management:resource:registry:imageFetch:containerSystemConfig:progressUpdate:log:) -> (ContainerConfiguration, Kernel, String?)` + `Utility.createContainerID(name:)` + `Utility.validEntityName`. `Flags.*` structs have public defaulted vars (`env, cwd, user, cpus, memory, publishPorts, mounts, volumes, networks, tmpFs, capAdd/Drop, labels, entrypoint, dns.*, virtualization, …`). Mirror `ContainerCommands/Container/ContainerRun.swift` / `ContainerCreate.swift`.
- **Images** — `ClientImage` (…/Client/ClientImage.swift): `static list()`, `static pull(reference:platform:scheme:containerSystemConfig:progressUpdate:maxConcurrentDownloads:)`, `static get(reference:containerSystemConfig:)`, `static delete(reference:garbageCollect:)`, `tag(new:)`, `push(platform:scheme:containerSystemConfig:progressUpdate:)`, `static save(references:out:platform:containerSystemConfig:)`, `static load(from:force:)`, `static getFullImageSize`, `static calculateDiskUsage`, `config(for:)`/`manifest(for:)` for inspect.
- **Config** — `ContainerSystemConfig` via `ConfigurationLoader.load(configurationFiles:)` using `SystemHealth.appRoot/installRoot` (copy the 8-line `Application.loadContainerSystemConfig()` from `ContainerCommands/Application.swift`; do not depend on `ContainerCommands`, it drags ArgumentParser/TTY).
- **System** — `ClientHealthCheck.ping(timeout:) -> SystemHealth { apiServerVersion, apiServerCommit, appRoot, installRoot }`; `ClientDiskUsage.get() -> DiskUsageStats`; `ClientKernel`.
- **Volumes** — `ClientVolume.list/create/delete/inspect/volumeDiskUsage`.
- **Networks** — `NetworkClient().list/get/create(configuration:)/delete`.
- **Progress** — `ProgressUpdateHandler` (`…/Client/ProgressUpdateClient.swift`) drives pull/push/unpack progress.
- **Registry** — `RegistryLogin`/`RegistryLogout` in `ContainerCommands/Registry/`; keychain ID `com.apple.container.registry`. Copy the keychain write logic, not the command.
- **Build** — CLI-only pipeline in `ContainerCommands/BuildCommand.swift` (gRPC `Builder` over `client.dial(id:"buildkit", port:)`). Hence `Process` in v1.
- **Not present**: any event/watch API → polling.

## Repository layout

```
macos-comtainer/                       (rename dir to dockyard optional)
├── Dockyard.xcodeproj
├── Dockyard/                          # app target (SwiftUI shell)
│   ├── DockyardApp.swift              # @main: WindowGroup + MenuBarExtra, injects AppModel
│   ├── AppModel.swift                 # @Observable root: DaemonState, stores, polling scheduler
│   ├── Sidebar/                       # Containers / Images / Volumes / Networks / System
│   ├── Containers/                    # list, detail (Overview, Logs, Stats, Terminal, Inspect), RunSheet
│   ├── Images/                        # list, detail, PullSheet, BuildSheet, PushSheet, RegistryLoginSheet
│   ├── Volumes/, Networks/, System/   # tables + create sheets; System: status, start/stop, df, version
│   ├── MenuBar/                       # MenuBarExtra content: daemon dot, running containers w/ stop, quick open
│   ├── Components/                    # LogTextView (NSViewRepresentable/NSTextView), TerminalView (SwiftTerm), KeyValueListEditor, ProgressRow
│   ├── Onboarding/                    # CLI missing / daemon stopped / version mismatch screens
│   ├── Dockyard.entitlements          # no sandbox
│   └── Info.plist                     # LSUIElement=false, NSSupportsSuddenTermination=false
├── Packages/DockyardCore/
│   ├── Package.swift                  # tools 6.2; deps: apple/container exact 1.0.0, SwiftTerm
│   ├── Sources/DockyardCore/
│   │   ├── Backend/
│   │   │   ├── ContainerBackend.swift     # protocol: all daemon ops (async, Sendable), returns Core models
│   │   │   ├── LiveBackend.swift          # wraps ContainerClient/ClientImage/ClientVolume/NetworkClient/ClientHealthCheck
│   │   │   ├── CLIRunner.swift            # Process wrapper for `container system start|stop` and `container build`; AsyncStream<String> of lines
│   │   │   └── SystemConfigLoader.swift   # copy of Application.loadContainerSystemConfig
│   │   ├── Models/                    # ContainerItem, ImageItem, VolumeItem, NetworkItem, DaemonStatus, PullProgress, RunSpec (→ Flags mapping)
│   │   ├── Stores/                    # ContainerStore, ImageStore, VolumeStore, NetworkStore, SystemStore (@Observable @MainActor), Poller
│   │   ├── Logs/                      # LogTailer: FileHandle → AsyncStream<LogLine>, ring buffer
│   │   ├── Terminal/                  # ExecSession: pipes ↔ ClientProcess, resize, exit
│   │   └── Registry/                  # keychain login/logout
│   └── Tests/
│       ├── DockyardCoreTests/         # MockBackend-driven unit tests
│       └── DockyardIntegrationTests/  # gated by DOCKYARD_INTEGRATION=1; needs running daemon
├── scripts/                           # build-app.sh, notarize.sh (later)
└── README.md
```

Design rules:
- Views never import apple/container modules; only `DockyardCore` does. Core models are plain structs so the UI compiles fast and the upstream dep can be swapped/upgraded in one file (`LiveBackend`).
- All stores are `@MainActor @Observable`; backend calls are `async` off-main via the actor-isolated `LiveBackend`.
- Every user action: optimistic status → await backend → `refresh()` → on error surface a non-modal toast + detail in System log.
- Errors from XPC ("Connection invalid") are mapped to `DaemonStatus.stopped` and route to the onboarding screen instead of per-row errors.

## Milestones (each ends runnable)

**M0 — Skeleton (day 1–2)**
1. Install Xcode 26. Create `Dockyard.xcodeproj` (macOS app, SwiftUI, deployment macOS 26, no sandbox) and `Packages/DockyardCore` with `apple/container` pinned `exact: "1.0.0"`. Confirm it resolves/builds (15 transitive packages; first build is slow).
2. `ContainerBackend` protocol + `LiveBackend` with `health()`, `listContainers()`, `listImages()`.
3. `SystemStore` + `DaemonStatus` state machine: `.cliMissing` (no `/usr/local/bin/container`) → `.stopped` (ping throws) → `.versionMismatch` → `.running`. `CLIRunner.systemStart()`/`systemStop()`.
4. Window with sidebar, Containers and Images tables (name/image/status/started; ref/tag/digest/size), Onboarding screen, MenuBarExtra with daemon dot. Poller (2s, pauses when window & menu hidden — `scenePhase` + `NSApp.isActive`).

**M1 — Container lifecycle + logs (day 3–5)**
5. Start/Stop/Kill/Delete (toolbar, context menu, menu bar). Start mirrors `ContainerStart.swift` (`bootstrap` + `process.start()`); Stop uses `ContainerStopOptions.default`; Delete with force confirm if running.
6. Detail view: Overview (config, mounts, networks, ports), Inspect (JSON of `ContainerSnapshot` via `JSONEncoder` pretty).
7. `LogTailer`: `client.logs(id:)` FileHandles → `bytes.lines` → ring buffer (100k lines) → `LogTextView` (NSTextView, monospaced, follow/pause, search, boot-log toggle).
8. Stats tab: poll `stats(id:)` 1s while visible; Swift Charts sparklines CPU/mem/net.

**M2 — Images: pull / run / delete (day 6–9)**
9. Pull sheet: reference + platform; `ClientImage.pull` with `ProgressUpdateHandler` → per-layer progress rows; cancel via Task cancellation.
10. Delete image (with "in use by N containers" guard from container list), Tag, Image inspect (`config(for:)`).
11. **Run sheet** (full): sections Basic (name, image, command, entrypoint, workdir, user), Ports, Env (+ env file), Mounts/Volumes/tmpfs, Resources (cpus, memory), Network (networks, DNS, hostname), Advanced (caps, labels, platform/arch, kernel, virtualization, tty/interactive, shm). `RunSpec` → `Flags.*` → `Utility.containerConfigFromFlags` → `client.create` → optional start. Tests for `RunSpec→Flags` mapping.

**M3 — Build + exec terminal (day 10–13)**
12. Build sheet: folder (NSOpenPanel + drop), Dockerfile picker (auto-detect `Dockerfile`/`Containerfile`), tag, platform, build-args, no-cache. `CLIRunner.build(...)` streams lines into `LogTextView`; cancel = SIGINT to process; on exit 0 → `ImageStore.refresh()`.
13. Terminal tab: SwiftTerm `TerminalView`; `ExecSession` creates 3 `Pipe`s, calls `createProcess(... stdio: [stdinRead, stdoutWrite, stderrWrite])` with `ProcessConfiguration(terminal: true, executable: "/bin/sh")` (fallback list `/bin/bash`,`/bin/sh`), forwards `resize`, `wait()` → shows exit code. Mirror `ContainerExec.swift`.

**M4 — Volumes, Networks, Registry, System panel (day 14–17)**
14. Volumes tab (`ClientVolume`), Networks tab (`NetworkClient`), create sheets, delete guards.
15. Registry login/logout sheet (keychain per `ContainerCommands/Registry/`), Push sheet with progress, Save-to-tar (NSSavePanel).
16. System panel: status, version (client vs server), start/stop with streamed output, `df` breakdown with prune buttons (`container prune` → `client.delete` loop over stopped; `cleanUpOrphanedBlobs`), open logs folder.

**M5 — Polish + release (day 18–20)**
17. Keyboard shortcuts, search/filter in tables, sort persistence, Settings (poll interval, default platform, launch at login via `SMAppService`).
18. `scripts/build-app.sh` (xcodebuild archive, Developer ID sign, notarize, dmg). GitHub Release workflow (build only; notarization needs secrets — document).
19. README with install steps (Apple pkg first, then Dockyard).

## Verification

- `cd Packages/DockyardCore && swift test` — unit tests with `MockBackend` (state transitions, poll pausing, error→DaemonStatus mapping, `RunSpec→Flags`, log ring buffer, build arg construction).
- `DOCKYARD_INTEGRATION=1 swift test --filter DockyardIntegrationTests` — against the real daemon: start system if needed, pull `docker.io/library/alpine:latest`, create+start container running `sleep 60`, assert `.running`, read logs, exec `echo hi` and assert output, stop, delete, delete image.
- Manual end-to-end per milestone: launch app with daemon stopped → onboarding → Start → lists populate; pull `nginx` → Run with port 8080:80 → open `http://localhost:8080` → Logs show requests → Stats move → Terminal `ls /` → Stop → Delete. Build a sample `Dockerfile` (`FROM alpine; RUN echo hi`) → image appears → Run.
- Overhead check: `ps`/Activity Monitor — Dockyard RSS < ~60 MB idle, ~0% CPU idle with window hidden (poller paused), no child processes except during build/system start.
