# Changelog

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
