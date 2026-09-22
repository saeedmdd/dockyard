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

## Acceptance
- [ ] `cd Packages/DockyardCore && swift build` succeeds.
- [ ] `xcodebuild -project Dockyard.xcodeproj -scheme Dockyard build` succeeds.
- [ ] App launches, shows window and menu bar icon, quits cleanly.
- [ ] `Package.resolved` pins `container` to `1.0.0` and `containerization` to `0.33.3`.

## Notes
