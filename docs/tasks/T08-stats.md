# T08 — Stats tab with charts

**Milestone:** M1 · **Depends on:** T06 · **Status:** todo

## Goal
Per-container CPU, memory, network and block I/O with live sparklines.

## Upstream references
- `Sources/Services/ContainerAPIService/Client/ContainerClient.swift` — `stats(id:) -> ContainerStats`.
- `Sources/ContainerResource/Container/ContainerStats.swift` (locate; fields for cpu usage, memory usage/limit, network rx/tx, block read/write).
- `Sources/ContainerCommands/Container/ContainerStats.swift` — how the CLI derives CPU % (delta of cumulative usage / interval) and formats.

## Files
- `Models/ContainerStatsSample.swift` — `timestamp, cpuPercent, memoryUsed, memoryLimit, netRx, netTx, blockRead, blockWrite`.
- `Backend/ContainerBackend.swift` — `stats(id:) -> RawStats`.
- `Stores/StatsStore.swift` — per selected container, 1s poll while Stats tab visible, keeps last 120 samples, computes CPU% from consecutive raw samples exactly as `ContainerStats.swift` does.
- `Dockyard/Containers/StatsView.swift` — 4 Swift Charts `LineMark` sparklines + current values; memory shows used/limit.
- `Tests/DockyardCoreTests/StatsStoreTests.swift` — CPU% derivation from two raw samples.

## Acceptance
- [ ] Run `alpine sh -c 'yes > /dev/null'` → CPU chart near 100% of one core; stop → drops to 0.
- [ ] Memory value matches `container stats <id>` within rounding.
- [ ] Leaving Stats tab stops the 1s poll (log/`isActive`).

## Notes
