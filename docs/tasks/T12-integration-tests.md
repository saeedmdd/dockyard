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
- [ ] `DOCKYARD_INTEGRATION=1 swift test --filter DockyardIntegrationTests` passes on this machine with the daemon running.
- [ ] Without the env var the suite is skipped (not failed) so `swift test` stays green in any environment.
- [ ] Suite leaves no containers/images with the test prefix behind (verify with `container list -a`, `container image list`).

## Notes
