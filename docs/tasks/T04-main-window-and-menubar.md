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
- [ ] With daemon running and ≥1 container/image (create via CLI), both tables populate within 2s of launch.
- [ ] `container run -d --name t1 alpine sleep 100` from terminal → row appears within one poll interval; `container stop t1` → status changes without user action.
- [ ] Hide window + close menu popover → Activity Monitor shows ~0% CPU; poller `isActive == false` (log line).
- [ ] Menu bar shows daemon dot and running count.
- [ ] `PollerTests`: pause/resume semantics, tickNow triggers immediate refresh (MockBackend call count).

## Notes
