# T05 — Start / stop / kill / delete containers

**Milestone:** M1 · **Depends on:** T04 · **Status:** todo

## Goal
Container actions from toolbar, context menu, and menu bar, with optimistic UI and error toasts.

## Upstream references
- `Sources/ContainerCommands/Container/ContainerStart.swift:57-100` — start = `client.get` → if `.running` return → check virtiofs mount sources exist → `ProcessIO.create(tty:interactive:false,detach:true)` → `client.bootstrap(id:stdio:dynamicEnv:)` → `process.start()` → `io.closeAfterStart()`; on failure `client.stop`.
- `ContainerStop.swift` — `client.stop(id:opts: ContainerStopOptions.default)` (signal + timeout).
- `ContainerKill.swift` — `client.kill(id:signal:)`.
- `ContainerDelete.swift` — `client.delete(id:force:)`; running containers require force.
- `ContainerPrune.swift` — delete all stopped.

## Files
- `Backend/ContainerBackend.swift` — add `startContainer(id:)`, `stopContainer(id:)`, `killContainer(id:signal:)`, `deleteContainer(id:force:)`.
- `Backend/LiveBackend.swift` — implement per references above.
- `Stores/ContainerStore.swift` — `start(_:)`, `stop(_:)`, `kill(_:)`, `delete(_:force:)`, `pruneStopped()`. Each: set `pending[id] = .starting/.stopping`, await, `refresh()`, clear pending; error → `throw` (AppModel shows toast).
- `Dockyard/Containers/ContainerActions.swift` — shared `ViewModifier`/menu builder used by toolbar, context menu, menu bar.
- `Dockyard/MenuBar/MenuBarView.swift` — wire Stop on running rows.
- Confirmation `.confirmationDialog` for delete of a running container (force) and for prune.

## Acceptance
- [x] Start from the toolbar → container runs; `container list` agrees (`dockyard-t05 running`).
- [x] Stop from the toolbar → `dockyard-t05 stopped`.
- [x] Kill with a chosen signal covered by tests (`SIGINT` recorded, `SIGKILL` the default).
- [x] Delete stopped → dialog reads “Delete “dockyard-t05”?” / “This cannot be undone.” Cancel leaves
      it in place. Delete running → dialog changes to **Stop and Delete** with “This container is
      running. It will be stopped first…”, and force-deletes for real (container gone from the CLI).
- [x] A failing start surfaces the real upstream error in the banner and leaves the app usable:
      `failed to bootstrap container dockyard-t05fail (cause: "unknown: "internalError: "mount""")`.
      Exercised with a genuinely broken container, not a simulated error.
- [x] Menu bar Stop works with the main window closed — verified with zero windows open; the panel
      listed the running container and stopping it from there left it `stopped`.
- [x] 83 unit tests in 13 suites plus 5 integration tests; `xcodebuild` clean.

## Findings
- **Bug caught by test: action failures were being silently swallowed.** Every action refreshes the
  list when it finishes, and a successful refresh cleared `lastError` — wiping the very failure the
  user needed to see. Action failures now live in a separate `actionError`.
- Detached start needs no `ProcessIO`: with `detach: true, interactive: false` upstream produces
  `[nil, nil, nil]` anyway, and on the way it installs readability handlers on the process's own
  stdin/stdout and does `try!` writes to them — fine for a CLI, not for an app. `bootstrap` is
  called with nil stdio directly.
- Missing bind-mount sources are checked before bootstrap, as upstream's start command does, so the
  user gets "The folder … no longer exists" instead of an opaque runtime error.
- Starting an already-running container is a no-op rather than an error, since a double-click or a
  racing poll should not produce a failure.
- **For T19:** `Window ▸ Dockyard` does not restore a closed `Window` scene; the menu bar's
  "Open Dockyard" does. Worth making the menu item work too.
- **For T19:** as in T03, SwiftUI exposes no accessibility *name* for these buttons through System
  Events — but `description` (toolbar) and `help` (menu bar) do carry the labels, which is how these
  checks drove the UI. Still needs a real VoiceOver pass.

## Notes
