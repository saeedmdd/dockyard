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
- [x] With daemon stopped the app shows onboarding ("The container system isn't running"); clicking
      Start runs `container system start` and ends in `.running`. Verified end to end against the
      real daemon: stopped it from the terminal, refreshed the app, clicked Start, and confirmed
      from outside that the app itself registered the launchd job —
      `launchctl print gui/503/com.apple.container.apiserver` → `state = running`,
      `program = /usr/local/bin/container-apiserver`.
- [x] "CLI missing" screen verified **without touching `/usr/local/bin`**, via the new
      `DOCKYARD_CONTAINER_PATH` override; the screen names the path it looked for.
- [x] Version comparison unit-tested; mismatch is non-blocking (`isOperational == true`) and shows
      the banner with both versions.
- [x] `swift test` green: 53 unit tests in 9 suites, plus 5 gated integration tests. `xcodebuild`
      succeeds with no new warnings.
- [x] Streaming, failure, double-click and cancellation paths covered by tests against a scripted
      `DaemonController` rather than UI timing.

## Findings
- **Bug caught by test: a double-click spawned a second `container system start`.** `start()` passed
  `cli.systemStart()` as an argument, which Swift evaluates at the call site — so the process was
  spawned *before* the `isTransitioning` guard could reject it. The stream is now produced by a
  closure evaluated after the guard.
- `container system stop` stops every running container before booting out the service, so any stop
  affordance needs a confirmation. Added one to the placeholder button; T18 carries it into the
  System panel.
- `system start` logs to **stderr** (bootstrap logger) while `system stop` logs to **stdout**, so
  `CLIRunner` captures and tags both. Tested.
- Introduced `DaemonController` so `SystemStore` is testable without a daemon; `CLIRunner` conforms.
- Added `CLIRunner.pathOverrideEnvironmentKey` (`DOCKYARD_CONTAINER_PATH`). T19's CLI-path setting
  should feed the same mechanism.
- **For T19:** SwiftUI buttons here expose no accessibility *name* through the System Events API —
  `Button("Check again")` reports `name: missing value`. Static text reads fine. Explicit
  `.accessibilityLabel` was added to the two primary actions; whether plain buttons are genuinely
  unreadable needs a check with VoiceOver itself rather than System Events.

## Notes
