# T18 — System panel: df, prune, versions, logs

**Milestone:** M4 · **Depends on:** T03 · **Status:** todo

## Upstream references
- `Sources/Services/ContainerAPIService/Client/ClientDiskUsage.swift` + `DiskUsage.swift` — `DiskUsageStats` (images/containers/volumes counts, sizes, reclaimable).
- `ClientImage.cleanUpOrphanedBlobs()`, `calculateDiskUsage(activeReferences:)`.
- `Sources/ContainerCommands/System/SystemDF.swift`, `SystemLogs.swift` (log root from `SystemHealth.logRoot`), `SystemVersion.swift`, `SystemProperty.swift`, `SystemKernel.swift`.
- `ClientKernel.swift` — default kernel info.

## Files
- `Models/DiskUsage.swift`.
- `Backend/ContainerBackend.swift` — `diskUsage()`, `pruneStoppedContainers()`, `pruneUnusedImages()` (delete images not referenced by any container + `cleanUpOrphanedBlobs`), `kernelInfo()`.
- `Stores/SystemStore.swift` — extend with `diskUsage`, `prune*`, `kernel`.
- `Dockyard/System/SystemView.swift` — sections: Status (dot, Start/Stop with streamed output from T03), Versions (app, linked client lib, apiserver, commit; mismatch highlighted), Disk usage (3 rows + reclaimable + Prune buttons with confirmation), Kernel (default kernel path/arch), Logs (button: open `logRoot` in Finder; embedded tail of latest apiserver log via `LogTextView`), Data folder (open `appRoot`).

## Acceptance
- [ ] Numbers match `container system df`.
- [ ] Prune stopped containers removes only stopped ones; prune images removes only unused, reports reclaimed bytes.
- [ ] Stop daemon from panel → app returns to onboarding; Start → back to normal, lists refill.
- [ ] Open logs folder opens Finder at `logRoot`.

## Notes
