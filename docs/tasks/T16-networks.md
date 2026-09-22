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
- [ ] Create `net1` → appears; `container network list` agrees; delete works when unused.
- [ ] Run container on `net1` → attached list shows it; IP shown in container Overview matches `container inspect`.
- [ ] `default` shows lock icon, delete disabled.

## Notes
