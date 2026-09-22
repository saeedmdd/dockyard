# T02 — Backend protocol, models, LiveBackend

**Milestone:** M0 · **Depends on:** T01 · **Status:** todo

## Goal
All daemon access goes through one `ContainerBackend` protocol. `LiveBackend` implements it with the
upstream client libraries; `MockBackend` (tests) implements it in-memory. Views never see upstream types.

## Upstream references (apple/container 1.0.0)
- `Sources/Services/ContainerAPIService/Client/ContainerClient.swift` — `list(filters:)`, `get(id:)`
- `Sources/Services/ContainerAPIService/Client/ClientImage.swift` — `static list()`, `getFullImageSize`
- `Sources/Services/ContainerAPIService/Client/ClientHealthCheck.swift` — `ping(timeout:) -> SystemHealth`
- `Sources/ContainerCommands/Application.swift` — `loadContainerSystemConfig()` (copy the body; do not depend on `ContainerCommands`)
- `Sources/ContainerResource/Container/ContainerSnapshot.swift` — `status: RuntimeStatus`, `networks`, `startedDate`, `configuration`

## Files
- `Sources/DockyardCore/Backend/ContainerBackend.swift`
  ```swift
  public protocol ContainerBackend: Sendable {
      func health() async throws -> DaemonHealth
      func listContainers() async throws -> [ContainerItem]
      func listImages() async throws -> [ImageItem]
      // extended by later tasks
  }
  ```
- `Sources/DockyardCore/Backend/LiveBackend.swift` — `public actor LiveBackend: ContainerBackend`. Holds `ContainerClient()`, lazily loads `ContainerSystemConfig` via `SystemConfigLoader` (invalidate on health failure).
- `Sources/DockyardCore/Backend/SystemConfigLoader.swift` — copy of `Application.loadContainerSystemConfig()`.
- `Sources/DockyardCore/Models/ContainerItem.swift` — `id, name, image, status: ContainerStatus (.stopped/.running/.stopping/.unknown), startedAt, platform, ports: [PortMapping], mounts: [MountInfo], networks: [String], raw: ContainerSnapshot?` (raw kept for Inspect; `@unchecked` boundary allowed here only).
- `Sources/DockyardCore/Models/ImageItem.swift` — `reference, repository, tag, digest, sizeBytes, createdAt, platforms`.
- `Sources/DockyardCore/Models/DaemonHealth.swift` — `apiServerVersion, commit, appRoot, installRoot`.
- `Sources/DockyardCore/Models/DockyardError.swift` — `enum DockyardError: LocalizedError { daemonUnreachable, cliMissing, upstream(String), … }` with `init(mapping error: any Error)` that detects the XPC "Connection invalid" case → `.daemonUnreachable`.
- `Tests/DockyardCoreTests/MockBackend.swift` — in-memory arrays, settable failures.
- `Tests/DockyardCoreTests/ErrorMappingTests.swift`.

## Acceptance
- [ ] `swift test` green with MockBackend + error-mapping tests.
- [ ] Throwaway executable/test (integration, gated) calling `LiveBackend().health()` against a running daemon returns version `1.0.0`.
- [ ] No file outside `Backend/` imports an upstream module (`grep -r "import Container" Sources | grep -v Backend/` is empty).

## Notes
