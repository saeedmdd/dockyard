# T15 — Volumes tab

**Milestone:** M4 · **Depends on:** T04 · **Status:** todo

## Upstream references
- `Sources/Services/ContainerAPIService/Client/ClientVolume.swift` — `list() -> [VolumeConfiguration]`, `create(...)`, `delete(name:)`, `inspect(_:)`, `volumeDiskUsage(name:)`.
- `Sources/ContainerCommands/Volume/*` — create options (driver, opts, labels, size).

## Files
- `Models/VolumeItem.swift` — `name, driver, mountpoint?, sizeBytes?, labels, createdAt, usedBy: [String]` (join with ContainerStore mounts).
- `Backend/ContainerBackend.swift` — `listVolumes()`, `createVolume(VolumeSpec)`, `deleteVolume(name:)`, `volumeDiskUsage(name:)`.
- `Stores/VolumeStore.swift` — refresh in the poller (lower frequency: every 5th tick).
- `Dockyard/Volumes/VolumesListView.swift` — table: name, driver, size, used by; detail pane with labels; Create / Delete toolbar.
- `Dockyard/Volumes/CreateVolumeSheet.swift` — name (validated), size (optional), labels KV.
- Delete guard: in-use volumes → dialog listing containers.
- T11 Run sheet's Storage section: volume picker sourced from `VolumeStore`.

## Acceptance
- [x] Create → list → delete verified against the real runtime: the volume appears in
      `listVolumes()` with the source path the runtime recorded, and is gone after deletion.
- [x] Creating the same name twice fails rather than silently succeeding.
- [x] Labels survive the round trip.
- [x] Disk usage is reported per volume, fetched on demand.
- [x] **A mounted volume is visible on the container** — a container created with `name:/data` reports
      the volume in its mounts, which is exactly what the delete guard reads.
- [x] Deleting a volume that does not exist fails.
- [x] 227 unit tests in 35 suites, 40 integration tests; `xcodebuild` clean.
- [ ] **UI not verified on screen** — the Mac's screen was locked for this task
      (`CGSSessionScreenIsLocked = Yes`), and a locked session will not let an app activate or create
      windows. The view compiles and is wired in; it has not been looked at.

## Findings
- **Fixed a real gap in the T12 fixture, found by this task.** `cleanUp()` removed containers and
  images but not volumes, and the per-test delete ran *before* the container holding the volume was
  removed — so the delete failed and `try?` swallowed it. Two volumes were left on the machine.
  Volume cleanup now lives in the fixture, ordered after containers, and a full run leaves zero
  behind. This is the same class of mistake T12 exists to prevent, and it only showed up because the
  leftovers were checked rather than assumed.
- Sizes are a separate call per volume, so the list does not price every row on every poll; each is
  fetched once when its row is first drawn and dropped when the volume disappears.
- The runtime's container list carries no mount information, so "used by" is built from container
  details as they are loaded, rather than paying for a detail fetch per container on every poll.
- Deleting a volume destroys its contents, so the confirmation says that plainly, and names the
  containers that mount it when there are any.

## Diagnostic note
A long detour went into the app not showing a window: it launched, stayed alive, registered its menu
bar item, but had no window and could not become frontmost. A bisect (reverting this task's UI and
rebuilding) ruled out the new code, and the cause turned out to be the locked screen. Worth
remembering before suspecting a regression next time.

## Notes
