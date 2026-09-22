# T01 — Toolchain + project skeleton

**Milestone:** M0 · **Depends on:** — · **Status:** todo

## Goal
A buildable Xcode app target `Dockyard` that links a local SPM package `DockyardCore`, which in turn
resolves `apple/container` at exactly `1.0.0`. Nothing functional yet.

## Prerequisite
- Xcode 26 installed and selected (`xcode-select -s /Applications/Xcode.app`; `swift --version` ≥ 6.2).
  Upstream `Package.swift` is `swift-tools-version: 6.2`; Xcode 16.4 cannot build it.

## Files
- `Dockyard.xcodeproj` — macOS App, SwiftUI lifecycle, bundle ID `com.saeedmdd.Dockyard`, deployment target macOS 26, **App Sandbox off**, Hardened Runtime on.
- `Dockyard/DockyardApp.swift` — `@main`, `WindowGroup { ContentView() }` + `MenuBarExtra("Dockyard", systemImage: "shippingbox") { Text("…") }`.
- `Dockyard/Info.plist` — `LSUIElement` = NO, `NSSupportsSuddenTermination` = NO.
- `Dockyard/Dockyard.entitlements` — empty (no sandbox).
- `Packages/DockyardCore/Package.swift`:
  ```swift
  // swift-tools-version: 6.2
  platforms: [.macOS(.v26)]
  dependencies: [
    .package(url: "https://github.com/apple/container.git", exact: "1.0.0"),
  ]
  targets: DockyardCore (deps: ContainerAPIClient, ContainerImagesServiceClient, ContainerNetworkClient, ContainerVersion — products of "container"),
           DockyardCoreTests, DockyardIntegrationTests
  ```
- `Packages/DockyardCore/Sources/DockyardCore/DockyardCore.swift` — `public enum DockyardCore { public static let version = "0.1.0" }`.
- `.gitignore` — Xcode/SPM standard (`.build/`, `xcuserdata/`, `DerivedData/`).
- `git init` if not a repo; initial commit.

## Steps
1. Verify Xcode 26 (`xcodebuild -version`).
2. Create package first, `swift build` it standalone — this validates the upstream pin resolves (15 transitive packages; expect several minutes).
3. Create the Xcode project, add the local package (File → Add Package Dependencies → Add Local), link `DockyardCore` to the app target.
4. `xcodebuild -scheme Dockyard build` succeeds; app launches to an empty window + menu bar item.

## Gotchas found while executing
- Upstream's git history is small (~2 MB) but the *transitive* graph is not: containerization pulls
  zstd (~53 MB), Yams (~29 MB), grpc-swift, swift-nio, async-http-client, swift-protobuf, swift-toml.
  First resolution is a multi-minute download.
- `swift` commands need `--disable-sandbox` in sandboxed shells (see `docs/WORKFLOW.md`).
- The `.xcodeproj` uses a `PBXFileSystemSynchronizedRootGroup` for `Dockyard/`, so new source files
  are picked up automatically — later tasks never edit `project.pbxproj`. Files that must *not* be
  compiled into the app (e.g. the entitlements) live outside that folder, in `Config/`.

## Acceptance
- [x] `cd Packages/DockyardCore && swift build` succeeds. (3328 tasks, 83.5s, no errors/warnings)
- [x] `swift test` green — 2 tests, 1 suite; integration suite correctly skipped.
- [x] `xcodebuild -project Dockyard.xcodeproj -scheme Dockyard build` succeeds. **BUILD SUCCEEDED**,
      no errors or warnings. Two benign notes: no AppIntents.framework, and "Disabling hardened
      runtime with ad-hoc codesigning" (expected until T20 supplies a Developer ID).
- [x] App launches, shows window and menu bar icon, quits cleanly. Verified via the accessibility
      API: window `Dockyard` present, menu bar 2 has 1 status item which opens its panel, and the
      window renders `Dockyard 0.1.0` / `Linked against container 1.0.0` — proving `DockyardCore`
      is linked and executing, not merely compiled. Bundle id `com.saeedmdd.Dockyard`, version
      `0.1.0`, signature adhoc.
- [x] `Package.resolved` pins `container` 1.0.0 and `containerization` 0.33.3 (34 pins total).

## Notes
- Xcode 27.0 / Swift 6.4 installed (exceeds the 6.2 minimum).
- Resolution took several attempts: GitHub connectivity here is intermittent and SwiftPM aborts the
  whole resolve on one repo's `SSL connection timeout`. The fetch cache persists, so retrying
  advances each time. ~357 MB cached across 19 repos before it completed.
- Both `Package.resolved` files are committed: the package's own, and Xcode's copy at
  `Dockyard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
