# T06 — Container detail: overview + inspect

**Milestone:** M1 · **Depends on:** T04 · **Status:** todo

## Goal
Selecting a container shows a tabbed detail pane. This task builds the frame (Overview, Inspect) that
T07 (Logs), T08 (Stats), T14 (Terminal) plug into.

## Upstream references
- `Sources/ContainerResource/Container/ContainerSnapshot.swift`, `ContainerConfiguration.swift` (same dir) — mounts, `publishedPorts`, `networks`, `initProcess`, `resources`, `platform`, `labels`.
- `Sources/ContainerCommands/Container/ContainerInspect.swift` — pretty JSON of the snapshot.

## Files
- `Models/ContainerItem.swift` — extend with `ContainerDetail` (mounts, ports, env, cwd, user, cpus, memoryBytes, labels, networks with IPs, kernel, image).
- `Backend/ContainerBackend.swift` — `getContainer(id:) -> ContainerDetail`, `inspectJSON(id:) -> String`.
- `Dockyard/Containers/ContainerDetailView.swift` — header (name, status, image, uptime, action buttons from T05), `TabView`: Overview | Logs | Stats | Terminal | Inspect (later tabs render "coming in T0x" placeholders until implemented).
- `Dockyard/Containers/ContainerOverviewView.swift` — grouped `Form`/`LabeledContent` sections: Process, Ports (click host port opens `http://localhost:<port>`), Mounts, Networks (IP copyable), Resources, Labels.
- `Dockyard/Containers/InspectView.swift` — monospaced, selectable, Copy button. Reused by image inspect (T10).

## Acceptance
- [ ] Select container → detail shows correct image, ports, mounts, networks, IP.
- [ ] Inspect JSON matches `container inspect <id>` fields.
- [ ] Deselect / delete selected → detail clears without crash.
- [ ] Detail refreshes on each poll (status/uptime change live).

## Notes
