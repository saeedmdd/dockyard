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
- [x] Ran `alpine sh -c 'yes > /dev/null'`. App reports **100.1% CPU** against the CLI's 106.60% —
      both "one core", the difference being that the CLI averages over a fixed 2s window while the
      app samples at 1 Hz.
- [x] Memory matches: app shows **2.3 MB of 1 GB (0.2%)**, CLI reports `memoryUsageBytes: 2449408`
      and `memoryLimitBytes: 1073741824` (2.34 MiB / 1.00 GiB).
- [x] Stopping the container from the terminal switches the tab to "Container isn't running" within
      one poll — no stale chart, no error banner.
- [x] Leaving the tab stops sampling: `onDisappear` calls `stop()`, and `stoppingEndsSampling`
      asserts no further readings are taken afterwards.
- [x] 129 unit tests in 20 suites, 8 integration tests; `xcodebuild` clean.

## Findings
- CPU% follows upstream exactly: `(cpuDelta / elapsed) × 100`, where 100% is one fully used core, so
  a container on four cores can legitimately read 400%. The app uses the *actual* elapsed time
  between readings rather than the nominal interval, which keeps the figure honest when a poll jitters.
- Every field of `ContainerStats` is optional, and counters reset when a container restarts. A
  counter going backwards is reported as a zero rate rather than an enormous negative one.
- The first reading cannot produce a rate, so the tab says "Measuring…" rather than drawing a flat
  line at zero that would read as "idle".
- Two display bugs were visible only by reading the real rendered output, not from the code:
  `.byteCount` spells out zero, so an idle container showed **"Zero kB/s"**; and a container using
  2 MB of a 1 GB limit rounded to **"0%"**. Both fixed — "0 bytes/s" and "0.2% of 1 GB".
- Sampling runs at 1 Hz only while the tab is visible, and history is bounded to 120 samples. Both
  follow directly from T07, where per-container work left running behind a hidden view was expensive.

## Notes
