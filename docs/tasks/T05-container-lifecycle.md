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
- [ ] Start a stopped container → dot turns yellow (pending) then green; `container list` agrees.
- [ ] Stop → grey. Kill (SIGKILL) → grey immediately.
- [ ] Delete stopped → row disappears. Delete running → confirmation → force delete.
- [ ] Start a container whose bind-mount source was removed → error toast with the upstream message, no crash.
- [ ] Menu bar Stop works with main window closed.
- [ ] `ContainerStoreTests`: pending state set/cleared, error propagates, refresh called after action.

## Notes
