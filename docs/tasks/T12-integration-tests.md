# T12 — Integration test suite against the real daemon

**Milestone:** M2 · **Depends on:** T11 · **Status:** todo

## Goal
A local-only, env-gated XCTest target exercising `LiveBackend` end-to-end so upstream bumps and
backend refactors are caught without clicking through the app.

## Files
- `Tests/DockyardIntegrationTests/IntegrationTestCase.swift` — base class: `XCTSkipUnless(ProcessInfo.processInfo.environment["DOCKYARD_INTEGRATION"] == "1")`; `setUp` ensures daemon running (`CLIRunner.systemStart()` if health fails), unique name prefix `dockyard-it-<uuid>`; `tearDown` deletes anything with that prefix.
- `Tests/DockyardIntegrationTests/LifecycleTests.swift` — pull `docker.io/library/alpine:3.20` → create via `RunSpec` (`sleep 60`) → start → assert `.running` → logs contain nothing/boot log non-empty → stop → assert `.stopped` → delete.
- `Tests/DockyardIntegrationTests/ImageTests.swift` — pull, tag, inspect, delete.
- `Tests/DockyardIntegrationTests/ExecTests.swift` (filled in T14) — `echo hi` → stdout `hi`.
- `Tests/DockyardIntegrationTests/StatsTests.swift` — two samples, non-negative values.
- `Package.swift` — add the test target.
- `docs/WORKFLOW.md` step 4 already references the command.

## Acceptance
- [x] `DOCKYARD_INTEGRATION=1 swift test` → **24 tests in 8 suites pass in ~13s** against the real
      daemon, creating and destroying real containers along the way.
- [x] Without the env var the suite is skipped, not failed, and the container count is unchanged —
      checked before and after (7 → 7).
- [x] Nothing is left behind: no container or image matching `dockyard-it-*` after a full run.
- [x] **Cleanup verified on the failure path**, not just the happy one — see below.
- [x] Unit tests (183) and `xcodebuild` still clean.

## What is covered
- Full lifecycle: create → start (asserting it gets an address) → stop → delete.
- Starting an already-running container is harmless; deleting a running one needs force; kill works.
- `RunSpec` options survive the round trip through `Flags` and `containerConfigFromFlags`: cpus,
  memory, working directory, labels, a published port, and an environment value containing `=`.
- An invalid name fails before anything is created.
- Logs: a container's output reaches `LogTailer` through the real log file, and a boot log exists.
- Stats: two readings produce a sample with sane values.
- Images: tag then delete leaves the original; deleting a shared tag reclaims **0 bytes**;
  infrastructure images are protected; detail resolves variants with attestations filtered out;
  pulling a cached image works and pulling a nonexistent one fails.

## Findings
- **The failure path is the one that matters, so it was tested directly.** A temporary probe created
  and started a container and then threw. The container was removed anyway, and the count returned
  to 7. `defer` cannot await, so `withFixture` catches, tears down, and rethrows — without that, a
  failing run would litter the developer's own daemon, which is exactly when they can least afford
  it.
- Every fixture namespaces itself with `dockyard-it-<uuid>` and deletes only what carries that
  prefix, so a run can never touch a container someone actually cares about.
- The suite starts the container system itself if it is not running, rather than failing every test
  with an XPC error and leaving the reason to be guessed.
- Exec is stubbed as an explicitly disabled test rather than omitted, so T14 has a named place to
  fill in rather than a gap someone has to notice.

## Notes
