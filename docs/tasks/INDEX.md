# Task index

Status: `todo` | `in-progress` | `done` | `blocked`. Execute per `docs/WORKFLOW.md`.

| ID | Task | Milestone | Depends on | Status |
|----|------|-----------|------------|--------|
| [T01](T01-toolchain-and-skeleton.md) | Toolchain + project skeleton | M0 | — | done |
| [T02](T02-backend-protocol-and-live-backend.md) | Backend protocol, models, LiveBackend | M0 | T01 | done |
| [T03](T03-daemon-state-and-onboarding.md) | Daemon state machine, CLIRunner, onboarding | M0 | T02 | todo |
| [T04](T04-main-window-and-menubar.md) | Main window, tables, poller, menu bar | M0 | T03 | todo |
| [T05](T05-container-lifecycle.md) | Start / stop / kill / delete containers | M1 | T04 | todo |
| [T06](T06-container-detail-overview-inspect.md) | Container detail: overview + inspect | M1 | T04 | todo |
| [T07](T07-logs-tailing.md) | Live log tailing | M1 | T06 | todo |
| [T08](T08-stats.md) | Stats tab with charts | M1 | T06 | todo |
| [T09](T09-pull-image.md) | Pull sheet with progress | M2 | T04 | todo |
| [T10](T10-image-delete-tag-inspect.md) | Image delete / tag / inspect | M2 | T09 | todo |
| [T11](T11-run-sheet.md) | Full Run sheet | M2 | T05, T10 | todo |
| [T12](T12-integration-tests.md) | Integration test suite against real daemon | M2 | T11 | todo |
| [T13](T13-build-sheet.md) | Build sheet via `container build` | M3 | T10 | todo |
| [T14](T14-exec-terminal.md) | Exec terminal (SwiftTerm) | M3 | T07 | todo |
| [T15](T15-volumes.md) | Volumes tab | M4 | T04 | todo |
| [T16](T16-networks.md) | Networks tab | M4 | T04 | todo |
| [T17](T17-registry-push-save.md) | Registry login, push, save | M4 | T10 | todo |
| [T18](T18-system-panel.md) | System panel: df, prune, versions, logs | M4 | T03 | todo |
| [T19](T19-polish-and-settings.md) | Search, shortcuts, settings, launch at login | M5 | T05–T18 | todo |
| [T20](T20-release-pipeline.md) | Build/sign/notarize scripts, README | M5 | T19 | todo |
