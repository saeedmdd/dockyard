# Changelog

## 0.2.0

Built against `apple/container` 1.4.1, up from 1.0.0.

### Why upgrade
On 1.0.0 any image with more than one layer failed to start with
`internalError: "mount"` — a single-layer image worked, three and eight did not —
and `container build` failed the same way, because the buildkit builder is
itself a multi-layer image. 1.4.1 fixes both and carries two security fixes in
Containerization.

**An upgrade alone is not enough.** An image unpacked by an older runtime keeps a
snapshot the new one cannot mount. Re-pull it, or rebuild it if it was built
locally, and the new runtime writes a snapshot it can use.

### Changed
- Container, volume and network names are validated in the app now.
  `Utility.validEntityName` was removed upstream; the rule is unchanged, but it
  is applied in the sheet where a bad name can still be fixed, rather than after
  a round trip to the daemon.
- "Automatic" registry scheme is resolved by Dockyard. Upstream removed
  `RequestScheme.auto` and changed the default from `auto` to `https`, which
  silently breaks a registry on this machine serving plain HTTP. Pull, push and
  run now all pick the scheme from the host.

### Added
- An app icon.

## 0.1.0

First release. Built against `apple/container` 1.0.0.

### Containers
- List with live status, ports, IP and uptime; start, stop, send a signal, delete.
- Detail pane: configuration, mounts, networks and ports, plus the raw `ContainerSnapshot` as JSON.
- Live logs, tailed from the runtime's own file handles, with search and follow.
- CPU, memory and network charts while a container is selected.
- A terminal, through `SwiftTerm`, attached to a process in the container.
- A Run sheet covering the full set of `container run` options, validated by the same code the CLI
  uses so anything it accepts the runtime accepts.

### Images
- List, inspect, tag and delete, with a guard naming the containers an image is about to strand.
- Pull with per-layer progress, and cancel.
- Build from a Dockerfile with streamed output.
- Registry sign-in stored in the same keychain item the CLI uses, so a login made in either is
  visible to both. Push, save to a tar archive, and load one back.

### Infrastructure
- Volumes and networks: create, inspect, delete, with the built-in network protected.
- System panel: daemon status with start and stop, version comparison between the linked client
  libraries and the running server, disk usage with a prune per resource, the default kernel, and
  the runtime's log.

### The app itself
- Menu bar item that works with the window closed: daemon state, running containers, stop buttons,
  and quick actions.
- Search on every list, keyboard shortcuts for everything, and settings for the poll interval,
  default platform, CLI path and launch at login.
