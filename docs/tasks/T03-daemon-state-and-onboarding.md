# T03 — Daemon state machine, CLIRunner, onboarding

**Milestone:** M0 · **Depends on:** T02 · **Status:** todo

## Goal
The app always knows one of: CLI missing → daemon stopped → version mismatch → running, and can start
or stop the daemon from the UI. This is the first thing a new user hits (on this machine the daemon is
not running).

## Upstream references
- `Sources/ContainerCommands/System/SystemStart.swift` — what `container system start` does (launchd plist at `~/Library/Application Support/com.apple.container/apiserver/apiserver.plist`, mach service `com.apple.container.apiserver`). We do **not** replicate it; we run the CLI.
- `Sources/ContainerCommands/System/SystemStatus.swift`, `SystemStop.swift`.
- `Sources/ContainerVersion/` — linked client version for the mismatch check.

## Files
- `Sources/DockyardCore/Backend/CLIRunner.swift`
  - `static let defaultPath = "/usr/local/bin/container"`, `static func isInstalled() -> Bool`.
  - `func run(_ args: [String]) -> AsyncThrowingStream<CLIEvent, Error>` where `CLIEvent = .stdout(String) | .stderr(String) | .exit(Int32)`. Uses `Process` + `Pipe`, line-buffered, cancellation → `SIGINT` then `terminate()`.
  - `func systemStart()`, `func systemStop()` convenience.
- `Sources/DockyardCore/Models/DaemonStatus.swift` — `enum DaemonStatus: Equatable { cliMissing, stopped, starting, stopping, versionMismatch(server: String, client: String), running(DaemonHealth) }`.
- `Sources/DockyardCore/Stores/SystemStore.swift` — `@MainActor @Observable final class SystemStore` with `status`, `refresh()`, `start()`, `stop()`, `outputLog: [String]` (streamed CLI lines). `refresh()` order: `CLIRunner.isInstalled()` → `backend.health()` (throws → `.stopped`) → compare versions → `.running`.
- `Dockyard/Onboarding/OnboardingView.swift` — three states: install link (`https://github.com/apple/container/releases`), "Start container system" button with streamed output, version-mismatch banner (non-blocking, "Continue anyway").
- `Dockyard/AppModel.swift` — owns `SystemStore` and (later) other stores; `toast(_:)`.
- `Tests/DockyardCoreTests/SystemStoreTests.swift` — state transitions with MockBackend (health throws → stopped; version differs → mismatch).

## Acceptance
- [ ] With daemon stopped: app shows onboarding with Start button; clicking runs `container system start`, streams its lines, ends in `.running`.
- [ ] Rename `/usr/local/bin/container` temporarily → app shows "CLI missing" screen with link (restore after).
- [ ] Version comparison unit-tested; mismatch shows banner but allows continuing.
- [ ] `swift test` green.

## Notes
