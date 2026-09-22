# T04 — Main window, tables, poller, menu bar

**Milestone:** M0 · **Depends on:** T03 · **Status:** todo

## Goal
The app is a usable read-only viewer: sidebar navigation, Containers and Images tables that stay
fresh via polling, and a menu bar item reflecting daemon state.

## Files
- `Sources/DockyardCore/Stores/Poller.swift` — `@MainActor final class Poller`: `start(interval:)`, `pause()`, `resume()`, `tickNow()`; runs a `Task` loop with `Task.sleep`; exposes `isActive`.
- `Sources/DockyardCore/Stores/ContainerStore.swift` — `items: [ContainerItem]`, `isLoading`, `lastError`, `refresh()`.
- `Sources/DockyardCore/Stores/ImageStore.swift` — same shape.
- `Dockyard/AppModel.swift` — creates stores, one `Poller` calling `containerStore.refresh()` + `imageStore.refresh()` + `systemStore.refresh()` (health is cheap). Pause when window not visible **and** menu bar popover closed; resume on `scenePhase == .active` / popover open.
- `Dockyard/Sidebar/SidebarView.swift` — sections: Containers, Images, Volumes, Networks, System (Volumes/Networks/System stubs until their tasks).
- `Dockyard/Containers/ContainersListView.swift` — `Table`: status dot, name, image, ports, started (relative). Selection drives detail (T06).
- `Dockyard/Images/ImagesListView.swift` — `Table`: repository, tag, digest (short), size (`ByteCountFormatter`), created.
- `Dockyard/MenuBar/MenuBarView.swift` — daemon dot (green/grey/red), running containers count, list of running containers (stop button wired in T05), "Open Dockyard", "Quit".
- `Dockyard/ContentView.swift` — `NavigationSplitView`; shows `OnboardingView` when `systemStore.status` is not `.running`/`.versionMismatch`.

## Acceptance
- [x] Both tables populate on launch against the real daemon: window title `Containers – 0 running of 7`
      and sidebar badges `7` / `8`, matching `container list -a` (7) and `container image list` (8,
      i.e. 10 images minus 2 runtime ones).
- [x] External changes appear with no user action, in both directions: `container run -d` from the
      terminal → `1 running of 8` within ~3s; `container stop` → `0 running of 8` within ~4s.
- [x] Hidden app stops polling. CPU time over 20s: **0.18s visible vs 0.02s hidden** (~0.9% → ~0.1%),
      a 9× drop. Measured with `ps -o time` deltas rather than eyeballing Activity Monitor.
- [x] Menu bar shows the daemon dot, version and running containers: `Running`, `container 1.0.0`,
      `dockyard-poll-test`. It also proved the menu resumes polling — that container was started
      while the app was hidden, and the panel showed it on open.
- [x] `PollerTests` + store tests: 70 unit tests in 12 suites, plus 5 integration tests.

## Findings
- **`deinit` cannot cancel the poll task**: `deinit` is nonisolated and the task is main-actor
  isolated. The loop holds `self` weakly instead and ends on the first tick after deallocation.
- Polling skips the list calls when the daemon is not operational, so a stopped system costs one
  cheap ping every 2s instead of three failing XPC round trips.
- Window visibility alone is not enough: a minimised or fully covered window is still "appeared", so
  `NSApplication.didChangeOcclusionStateNotification` is what actually gates the loop. Window and
  menu visibility are tracked separately, or whichever closed last would stop polling for both.
- Table sorting is applied in the view, not the store, so each poll's fresh data keeps the user's
  chosen order.
- `@Bindable` cannot project through a `let` reference property (`$model.images.showsInfrastructure`
  fails); bind through the store itself.
- **Environment, not app:** containers whose images were pulled by an older `container` release fail
  to bootstrap with `internalError: "mount"` from `container-runtime-linux`. Re-pulling the image
  (`alpine:3.20`) fixed it. Worth knowing before blaming Dockyard for a container that won't start.

## Notes
