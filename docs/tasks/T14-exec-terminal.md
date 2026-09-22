# T14 — Exec terminal (SwiftTerm)

**Milestone:** M3 · **Depends on:** T07 · **Status:** todo

## Goal
A Terminal tab on running containers that opens an interactive shell inside the container.

## Upstream references
- `Sources/Services/ContainerAPIService/Client/ContainerClient.swift` — `createProcess(containerId:processId:configuration:stdio:[FileHandle?]) -> ClientProcess`.
- `Sources/Services/ContainerAPIService/Client/ClientProcess.swift` — `start()`, `kill(_:)`, `resize(Terminal.Size)`, `wait() -> Int32`.
- `Sources/Services/ContainerAPIService/Client/ProcessIO.swift` — how stdio FileHandles are laid out (`[stdin, stdout, stderr]`, nil when not attached; with `tty: true` stdout/stderr may be merged — verify).
- `Sources/ContainerCommands/Container/ContainerExec.swift` — builds `ProcessConfiguration` (executable, arguments, env, cwd, user, `terminal: tty`), processId = random, handles SIGWINCH → `resize`.
- `ContainerResource/…/ProcessConfiguration.swift`.

## Dependencies
- Add `https://github.com/migueldeicaza/SwiftTerm` (from: latest 1.x) to `DockyardCore` package (or app target only — prefer app target; core exposes only pipes).

## Files
- `Sources/DockyardCore/Terminal/ExecSession.swift` — `@MainActor final class ExecSession`: creates `Pipe`s for stdin/stdout(/stderr), calls backend `exec(containerId:command:tty:env:cwd:user:stdio:)`, exposes `output: AsyncStream<Data>`, `write(Data)`, `resize(cols:rows:)`, `terminate()`, `exitCode`.
- `Backend/ContainerBackend.swift` — `exec(...) -> ExecHandle` (start/kill/resize/wait).
- `Dockyard/Components/TerminalView.swift` — `NSViewRepresentable` around `SwiftTerm.TerminalView`; delegate `send(data:)` → `session.write`, `sizeChanged` → `session.resize`; feeds `session.output` into `terminal.feed(byteArray:)`.
- `Dockyard/Containers/TerminalTab.swift` — shell picker (`/bin/sh` default; try `/bin/bash` if present), "New session", shows exit code banner when process ends; tab disabled when container not running.
- `Tests/DockyardIntegrationTests/ExecTests.swift` — non-tty `echo hi` → `hi`.

## Acceptance
- [x] Opening the Terminal tab starts a real shell: `ps` inside the container showed
      **`PID 4 /bin/sh`**, started by the app.
- [x] **Typing in Dockyard runs commands in the container**, verified from outside the app rather
      than by reading the screen: typed `touch /tmp/dockyard-typed`, then
      `container exec … ls -la /tmp/dockyard-typed` showed the file.
- [x] The session has a real pseudo-terminal — typed `test -t 0 && echo HAS-TTY …` and the container
      reported **`HAS-TTY`**. That is what makes shells, editors and colours behave.
- [x] Resize reaches the process: the integration test sends a resize then `stty size` and reads back
      **`40 120`**.
- [x] A stopped container refuses with a readable message rather than an opaque runtime error.
- [x] 213 unit tests in 33 suites; 34 integration tests including the 7 exec ones that fill the
      placeholder T12 left.

## Findings
- **SwiftTerm cannot be depended on by version.** Both 1.8.0 and 1.9.0 require a pre-release
  `swift-subprocess`, and SPM refuses that under any stable-version requirement
  (`kind = exactVersion` included). It is pinned by **revision** —
  `8840e3596739adfe9599c0e7fff89f4fa88bedcf`, which is v1.9.0 — which both satisfies SPM and stays
  exactly reproducible.
- **SwiftTerm 1.9.0 needs Xcode's Metal Toolchain** (838.9 MB), which was not installed. Downloaded
  with `xcodebuild -downloadComponent MetalToolchain` after asking. Anyone building this from a
  clean Xcode will need it too.
- It also ships a build plugin: `xcodebuild` needs `-skipPackagePluginValidation`, and Xcode shows a
  one-time "Trust & Enable" prompt. **This flag is now required to build the app from the command
  line** and belongs in T20's scripts.
- `TerminalViewDelegate` is nonisolated, so the coordinator cannot be `@MainActor` — the compiler
  rejects the conformance as a data race. It is nonisolated and hops to the main actor for the two
  things that touch the view.
- Exec starts from the container's **own init process configuration**, as upstream's `container exec`
  does. That is what carries the image's `PATH`; without it a bare `ls` would not resolve. Pinned by
  a test.
- The shell is chosen by probing: `/bin/bash` then `/bin/sh`. Minimal images routinely have only
  `sh`, and asking for bash there fails with an error that mentions nothing about shells.

## Testing note
SwiftTerm's view exposes no focusable accessibility element — only a scrollbar — so its keyboard path
cannot be driven by the accessibility API the way the rest of this app has been. It was verified by
clicking at real screen coordinates inside the view and then checking the *container's filesystem*
for the effect, which is a stronger check than reading the rendered text would have been.

## Notes
