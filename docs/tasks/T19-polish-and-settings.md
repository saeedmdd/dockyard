# T19 — Search, shortcuts, settings, launch at login

**Milestone:** M5 · **Depends on:** T05–T18 · **Status:** todo

## Files
- Search field (`.searchable`) on Containers, Images, Volumes, Networks; filters by name/image/tag.
- Table sort persistence per table (`@AppStorage` of `KeyPathComparator` ids).
- Keyboard shortcuts: ⌘1–5 sidebar, ⌘N Run, ⌘⇧P Pull, ⌘B Build, ⌘R refresh now (`poller.tickNow()`), ⌘⌫ delete selected (confirm), ⌘. stop selected, ⌘↩ start selected, ⌘F search in logs.
- `Dockyard/Settings/SettingsView.swift` (`Settings` scene): poll interval (1–10s), default platform, show infra images, hide window on launch (menu bar only mode), launch at login via `SMAppService.mainApp` with status readback, CLI path override (default `/usr/local/bin/container`).
- Menu bar: quick actions Run… / Pull… / open System; window restoration.
- Toasts: single `ToastHost` overlay in `ContentView`, auto-dismiss 6s, click → System log with full error text.
- Empty states for every list with a primary action (e.g. "Pull an image").
- Accessibility labels on status dots and icon-only buttons.

## Acceptance
- [ ] Every shortcut above works and appears in the menu bar menus.
- [ ] Launch at login toggle registers/unregisters (`sfltool dumpbtm` or System Settings → Login Items shows Dockyard).
- [ ] Poll interval change takes effect without restart.
- [ ] VoiceOver reads container status.

## Notes
