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
- [x] Selecting a container shows the right data. Verified against a purpose-built container with
      ports, a read-only bind mount, custom cpus/memory and awkward env values: Command `sleep 600`,
      User `0:0`, port `80/tcp in container`, mount `/usr/share/nginx/html ← /tmp/…/t06site` marked
      `read-only` and typed `Folder`, CPUs `2`, Memory `512 MB`, Platform `linux/arm64`.
- [x] Inspect JSON matches `container inspect`. Proven by a parity test that runs both and compares
      the decoded objects key-for-key, rather than assuming two encoders agree.
- [x] Deselect and missing-container paths clear the pane without crashing (unit tests; the
      `notFound` path also covered against the real daemon).
- [x] Detail refreshes on each poll, so status and uptime stay live while the pane is open.
- [x] 96 unit tests in 16 suites, 8 integration tests, `xcodebuild` clean.

## Findings
- **`Filesystem.FSType` has only four public cases** — `block`, `volume`, `virtiofs`, `tmpfs`. The
  `rootfs`/`data` names visible when skimming the file belong to a `package`-internal sub-enum and
  are not reachable from a client. The root filesystem is therefore identified by its destination
  (`/`) rather than by type, and hidden from the Mounts list as an implementation detail.
- **Environment values routinely contain `=`** (`QUERY=a=1&b=2`), so parsing splits on the *first*
  `=` only. Verified end to end: the UI shows `a=1&b=2` intact.
- `ContainerStatus` is ambiguous inside DockyardCore — upstream has its own struct of that name, and
  the local enum shadows it. The inspect encoder qualifies `ContainerResource.ContainerStatus`.
- `container inspect` serialises `ManagedContainer`, not `ContainerSnapshot`, so the app builds the
  same wrapper to keep the output identical.
- Inspect JSON is fetched only when its tab is opened, and once per selection: it is a second round
  trip that most users never ask for.
- The detail pane sits beside the table in an `HSplitView` rather than replacing it, so the user
  keeps their place in the list. Note this changes the accessibility hierarchy, which matters when
  driving the UI in tests.
- Host-folder mounts that no longer exist are flagged in the Mounts list, since that is precisely
  what makes Start fail (see T05's pre-flight check).

## Notes
