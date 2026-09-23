# T19 — Search, shortcuts, settings, launch at login

**Milestone:** M5 · **Depends on:** T05–T18 · **Status:** done

The login item was verified in T20, once there was a build to install. See the correction below.

## Files
- `Models/Search.swift` — one `Searchable` rule for all four lists, plus the two sort keys that need
  a fallback (untagged images, containers that never ran).
- `Settings/AppSettings.swift` — poll interval, default platform, infrastructure images, start
  hidden, CLI path, per-table sort. Backed by `UserDefaults` directly, since the poller and the
  backend read it and there is no view there to hang `@AppStorage` on.
- `Settings/LoginItem.swift` — `SMAppService.mainApp` behind a protocol, with the refusal states
  spelled out.
- `Dockyard/Settings/SettingsView.swift` — General and Advanced tabs.
- `Dockyard/Commands/DockyardCommands.swift` — every shortcut, in the menus.
- `Dockyard/Components/ToastHost.swift`, `PlainTextLogView.swift`, `SortPersistence.swift`,
  `StringExtras.swift`.
- `Dockyard/AppDelegate.swift` — start hidden, and stay alive with no window.
- Search, empty-state actions and sort persistence across the four list views.

## Acceptance
- [x] **Every shortcut works and appears in the menu bar menus.** Verified by reading the menus
      through the accessibility API and by pressing them: ⌘N, ⌘⇧P, ⌘B (File), ⌘F, ⌘⇧F (Edit), ⌘R and
      ⌘1–⌘5 (View), ⌘↩, ⌘. and ⌘⌫ (Container). ⌘3/⌘5/⌘1 moved between sections; ⌘⌫ opened the delete
      confirmation for the selected container; ⌘F focused the search field; ⌘B opened the Build
      sheet; ⌘⇧P pulled an image end to end.
- [x] **Poll interval takes effect without restart.** With the setting at 10s a volume created from
      the CLI took 4.7s to appear; at 1s its deletion showed in 1.0s. The value persisted to
      `com.saeedmdd.Dockyard.pollIntervalSeconds`.
- [x] **VoiceOver reads container status.** The name cell reports "elasticsearch-node2, Stopped" —
      the state otherwise exists only as a coloured dot in a column of its own.
- [x] **Launch at login registers and unregisters.** Verified in T20 against the Release build
      installed in `/Applications`: the toggle turned on, survived a relaunch and a reinstall, then
      turned off and stayed off. Doing this found a bug in the code below.

Also verified in the running app: search filtering ("elastic" → 3 of 6, "elastic node2" → 1 of 6),
the no-results state and its Clear Search button, Escape clearing the field, the toast after
deleting an image ("Deleted docker.io/library/busybox:1.36 · reclaimed 678.3 MB"), the menu bar
quick actions, and start-in-the-menu-bar (launched with no window, "Open Dockyard" brought it back).
315 unit tests in 46 suites, 56 integration tests, `xcodebuild` clean. The machine was left as
found: 6 containers, 9 images, 0 volumes.

## Findings

- **A menu command that switched section and opened a sheet in the same tick did nothing.** ⌘B and
  ⌘⇧P set `selectedSection` and a `Bool`, but the Images screen does not exist yet at that moment,
  so its `onChange` never fired — and the flag stayed `true`, which made every later press a no-op
  too. The shortcut was dead for the rest of the session after one use. Both are counters now, read
  on appear as well as on change; ⌘N had the same latent race and got the same treatment.
- **⌘F went to the log search, which is only reachable with a container open.** The task sheet
  assigned ⌘F to the logs, but that is the shortcut people press to filter a list. ⌘F now focuses
  the current list's search field and ⌘⇧F the log search. Focusing a `.searchable` field from a menu
  needs `searchable(text:isPresented:)` — there is no focus binding for one.
- **`BuildStore.onSuccess` could not be an init parameter.** The object that wants the callback is
  the one that owns the store, and it cannot capture itself until it is fully initialised; as an
  init parameter this failed to compile with "used before being initialized". It is a settable
  property.
- **Accessibility labels reach toolbar items but not in-content buttons.** Through the accessibility
  API — the same one VoiceOver reads — toolbar buttons report their label, while buttons inside the
  content (prune, Start/Stop in the System panel, everything in the menu bar panel) report no title
  and no description at all, with or without `.accessibilityLabel`. The labels are set regardless;
  what carries the information today is the row text, which does read correctly.
- **The `container system df` parity test failed most runs until the cheap call went on the
  outside.** It brackets one reading between two others and accepts a match with either end. With
  two `container system df` process launches around one XPC call the window was wide enough that the
  parallel suites changed something inside it nearly every time; with the XPC calls outside and one
  process launch inside, the window is about half as wide and it is reliably green.
- Sorts are stored as a column name plus a direction, not an index: renaming or reordering a column
  would otherwise silently start sorting by the wrong thing. A saved sort whose column the view no
  longer lists is forgotten rather than half-applied.
- The poll interval is clamped on the way in as well as on the way out, and the change notification
  reports the clamped value — otherwise a hand-edited plist could retime the poller to something the
  settings do not hold.

## Correction: launch at login, and a bug it was hiding

This task recorded launch at login as unverifiable because `SMAppService.mainApp.status` reported
`notFound`, and concluded a signed build was needed. Both halves were wrong, and T20 showed why once
there was something to install.

The status depends on **where the app is, not how it is signed**: from `/Applications` an ad-hoc
build registers fine. And `notFound` is not a dead end at all — it is what the system reports for an
app that has simply never been registered. Dockyard mapped it to "macOS cannot find this copy of
Dockyard", which put a dead-end message underneath a toggle that would have worked had anyone
pressed it. It is now an ordinary off state; only a refusal thrown by `register()` is reported.

The lesson is narrower than "development builds cannot do this": a status was read as a verdict when
it was only a starting state, and the assumption went unchallenged because the environment made it
expensive to test. Verifying it cost one install.

## Notes
`nilIfEmpty` moved from a `fileprivate` in `RunSheet.swift` to `Components/StringExtras.swift`; the
second caller in `AppModel` would otherwise have needed its own copy.
