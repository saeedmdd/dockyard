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

Confirmed while doing T01:
- `ContainerClient` is a `public struct ... Sendable` holding a reusable `XPCClient`, so `LiveBackend`
  can be a `Sendable` struct; an actor is only needed for cached `ContainerSystemConfig`.
- Every client call wraps failures in `ContainerizationError` (`.internalError`, with `cause`), so
  `DockyardError.init(mapping:)` must unwrap that and inspect `cause` for the XPC
  `"Connection invalid"` case. Add `.product(name: "ContainerizationError", package: "containerization")`
  to the `DockyardCore` target dependencies.

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
- [x] `swift test` green: 29 unit tests in 7 suites, zero warnings.
- [x] Gated integration tests against the running daemon: 5 tests pass. `LiveBackend().health()`
      reports `1.0.0`; list calls return real data.
- [x] No file outside `Backend/` imports an upstream module — verified by grep.
- [x] Conversions checked against the CLI on real data: container count 7 = 7; image count 10 with
      2 flagged infrastructure = the CLI's 8; digests (`51183f2cfa63`, `e31753d05250`,
      `0ce1b8559ae3`), port strings (`0.0.0.0:9200->9200/tcp`) and denormalized references
      (`docker.io/library/alpine:latest` → `alpine:latest`) all match.
- [x] `xcodebuild` still succeeds.

## Findings
- **The apiserver does not report a bare semver.** `health.apiServerVersion` is the whole sentence
  `"container-apiserver version 1.0.0 (build: release, commit: ee848e3)"`, because the server sends
  `ReleaseVersion.singleLine(appName:)` and `container system version` prints it unparsed. Caught by
  the integration test. `DaemonHealth.semanticVersion` extracts `x.y.z`; an unparseable version is
  treated as a match so the app never blocks a user over a string it merely failed to read. **T03's
  mismatch banner must compare `semanticVersion`, not `apiServerVersion`.**
- `ContainerizationError` has no SPM product of its own — depend on the `Containerization` library.
- `ContainerSystemConfig` and `ConfigurationLoader` live in `ContainerPersistence`.
- `isInfraImage` compares against the *currently configured* builder and vminit images only, so older
  copies (`vminit:0.16.1`, `builder:0.6.0`) are not flagged. That matches `container image list`.
- `logRoot` is absent on this install, so the field must stay optional.
- `listImages()` returns every image with an `isInfrastructure` flag rather than filtering, leaving
  the choice to the UI; the CLI hides them by default and T10 adds that toggle.

## Notes
