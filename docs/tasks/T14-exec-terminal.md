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
- [ ] Open Terminal on a running `alpine` container → `ls /` output renders, colours via `ls --color` work, arrow keys/history work in `sh`.
- [ ] Resize window → `stty size` inside reflects new cols/rows.
- [ ] `exit` → banner "exited (0)"; New session works again.
- [ ] Stopping the container while a session is open → session ends cleanly, no crash.
- [ ] Integration exec test passes.

## Notes
