# T16 — Networks tab

**Milestone:** M4 · **Depends on:** T04 · **Status:** todo

## Upstream references
- `Sources/Services/ContainerAPIService/Client/NetworkClient.swift` — `list() -> [NetworkResource]`, `get(id:)`, `create(configuration: NetworkConfiguration) -> NetworkResource`, `delete(id:)`.
- `Sources/ContainerResource/Network/*` — `NetworkConfiguration` (id, mode, subnet, labels), `NetworkResource` (state, allocator info).
- `Sources/ContainerCommands/Network/*` — create flags; `default` network cannot be deleted.

## Files
- `Models/NetworkItem.swift` — `id, mode, subnet?, gateway?, state, labels, attachedContainers: [String]` (join with ContainerStore networks).
- `Backend/ContainerBackend.swift` — `listNetworks()`, `createNetwork(NetworkSpec)`, `deleteNetwork(id:)`.
- `Stores/NetworkStore.swift`.
- `Dockyard/Networks/NetworksListView.swift`, `CreateNetworkSheet.swift` (id, subnet optional, labels).
- Delete guard: `default` and networks with attached containers.
- T11 Run sheet's Network section: multi-select sourced from `NetworkStore`.

## Acceptance
- [x] Create → list → delete verified against the real runtime.
- [x] A container attached to a network reports it, which is exactly what the delete guard reads —
      verified by creating a network, running a container on it, and reading the container's
      attachments back.
- [x] The built-in network is present with a subnet and gateway, and **deleting it is refused**; it
      is still there afterwards. The UI also shows it with a lock and disables Delete.
- [x] Deleting a network that does not exist fails.
- [x] 241 unit tests in 37 suites, 44 integration tests; `xcodebuild` clean.
- [x] No leftovers: only `default` and the user's own `esnet` remain.
- [x] **UI verified once the screen was unlocked.** The Networks tab listed both networks; the
      `default` detail pane showed Mode `NAT`, Subnet `192.168.64.0/24` and Gateway `192.168.64.1`,
      matching `container network list`. With it selected the toolbar reported `Delete=false`, so the
      built-in network genuinely cannot be deleted from the UI.

## Findings
- `NetworkConfiguration` requires a `plugin`, which has no default on the type. The CLI's own default
  is `container-network-vmnet`, and the app names the same one so its networks are identical to the
  ones `container network create` makes.
- **The subnet and gateway live on the status, not the configuration.** They are assigned when the
  network comes up, so reading them from the configuration would show nothing for a running network.
- Refusing to delete the built-in network is done in the backend with a reason, rather than relying
  on the runtime to fail somewhere deeper with a message that does not mention why.
- Subnet input is validated as CIDR before it is sent, since a malformed one otherwise fails inside
  the runtime with an error that does not say which field was wrong.
- The fixture now cleans up networks too, ordered with containers first, for the same reason T15
  found with volumes.

## Notes
