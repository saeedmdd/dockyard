# Task index

Status: `todo` | `in-progress` | `done` | `done*` (done, one check blocked by the environment) | `blocked`. Execute per `docs/WORKFLOW.md`.

| ID | Task | Milestone | Depends on | Status |
|----|------|-----------|------------|--------|
| [T01](T01-toolchain-and-skeleton.md) | Toolchain + project skeleton | M0 | — | done |
| [T02](T02-backend-protocol-and-live-backend.md) | Backend protocol, models, LiveBackend | M0 | T01 | done |
| [T03](T03-daemon-state-and-onboarding.md) | Daemon state machine, CLIRunner, onboarding | M0 | T02 | done |
| [T04](T04-main-window-and-menubar.md) | Main window, tables, poller, menu bar | M0 | T03 | done |
| [T05](T05-container-lifecycle.md) | Start / stop / kill / delete containers | M1 | T04 | done |
| [T06](T06-container-detail-overview-inspect.md) | Container detail: overview + inspect | M1 | T04 | done |
| [T07](T07-logs-tailing.md) | Live log tailing | M1 | T06 | done |
| [T08](T08-stats.md) | Stats tab with charts | M1 | T06 | done |
| [T09](T09-pull-image.md) | Pull sheet with progress | M2 | T04 | done |
| [T10](T10-image-delete-tag-inspect.md) | Image delete / tag / inspect | M2 | T09 | done |
| [T11](T11-run-sheet.md) | Full Run sheet | M2 | T05, T10 | done |
| [T12](T12-integration-tests.md) | Integration test suite against real daemon | M2 | T11 | done |
| [T13](T13-build-sheet.md) | Build sheet via `container build` | M3 | T10 | done |
| [T14](T14-exec-terminal.md) | Exec terminal (SwiftTerm) | M3 | T07 | done |
| [T15](T15-volumes.md) | Volumes tab | M4 | T04 | done |
| [T16](T16-networks.md) | Networks tab | M4 | T04 | done |
| [T17](T17-registry-push-save.md) | Registry login, push, save | M4 | T10 | done* |
| [T18](T18-system-panel.md) | System panel: df, prune, versions, logs | M4 | T03 | done |
| [T19](T19-polish-and-settings.md) | Search, shortcuts, settings, launch at login | M5 | T05–T18 | done |
| [T20](T20-release-pipeline.md) | Build/sign/notarize scripts, README | M5 | T19 | done* |
| [T21](T21-compose-plumbing.md) | Compose plumbing: Yams, label listing, DNS reads | M6 | T20 | done |
| [T22](T22-compose-parsing.md) | Compose parsing, interpolation, service graph | M6 | T21 | done |
