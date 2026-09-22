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
- [ ] Create `data1` → appears; `container volume list` agrees. Delete → gone.
- [ ] Run a container with `data1:/data` → Volumes shows "used by" that container; delete blocked.
- [ ] Sizes match `container volume inspect` / `system df`.

## Notes
