# Implementation workflow

Every task in `docs/tasks/` is executed with the same loop. One task per session/branch. Do not start a
task whose `Depends on` list is not all `done`.

## 1. Pick

- Open `docs/tasks/INDEX.md`, take the first task with status `todo` whose dependencies are `done`.
- Set its status to `in-progress` in `INDEX.md`.
- `git checkout -b task/T<nn>-<slug>` from `main`.

## 2. Read

- Read the task file fully: goal, upstream references, files, steps, acceptance criteria.
- Read the upstream reference files it names (extract 1.0.0 source: `git clone --depth 1 -b 1.0.0 https://github.com/apple/container ../container-1.0.0` if not present). Never guess an API — open the file.
- Read any existing Dockyard files the task touches.

## 3. Implement (core first, UI second)

- Add/modify code in `Packages/DockyardCore` first. Keep views free of `import ContainerAPIClient` etc.; only `LiveBackend`/`CLIRunner`/`SystemConfigLoader` import upstream modules.
- Then the SwiftUI/AppKit layer in `Dockyard/`.
- Match existing naming and structure. No new dependencies unless the task file lists them.

## 4. Test

- `cd Packages/DockyardCore && swift build && swift test` — must be green.
  - First resolution downloads ~200 MB across 16 repos. On a flaky link SwiftPM aborts with
    `fatal: unable to access '...': SSL connection timeout`. Re-run — the fetch cache in
    `~/.swiftpm/cache/repositories` persists, so each attempt makes progress. To make aborts
    less likely, export before resolving:
    ```sh
    export GIT_CONFIG_COUNT=3 \
      GIT_CONFIG_KEY_0=http.version   GIT_CONFIG_VALUE_0=HTTP/1.1 \
      GIT_CONFIG_KEY_1=http.lowSpeedLimit GIT_CONFIG_VALUE_1=0 \
      GIT_CONFIG_KEY_2=http.lowSpeedTime  GIT_CONFIG_VALUE_2=999999
    ```
  - Never leave two SwiftPM processes running against the same `.build`: they deadlock on its
    lock and look like a hang. `pkill -f swift-package` before retrying.
- If the task has integration criteria: `container system start` then `DOCKYARD_INTEGRATION=1 swift test --filter DockyardIntegrationTests`.
- `xcodebuild -project Dockyard.xcodeproj -scheme Dockyard -configuration Debug build` — must succeed with zero warnings introduced by this task.

## 5. Manual check

- Launch the app (`open build/.../Dockyard.app` or Xcode ⌘R) and walk every acceptance criterion in the task file. Tick each one in the task file (`- [x]`).
- Overhead check on tasks that add polling/streaming: Activity Monitor idle CPU ≈ 0% with window hidden; no stray child processes.

## 6. Close

- Update the task file: status `done`, note deviations under `## Notes`.
- Update `docs/tasks/INDEX.md`.
- If a decision in `docs/PLAN.md` changed, edit the decision table there in the same commit.
- Commit: `T<nn>: <imperative summary>` with body listing acceptance criteria verified. Merge to `main` (fast-forward or squash).

## Conventions

- Swift 6 strict concurrency. Stores are `@MainActor @Observable`; backend is an `actor` or `Sendable` struct.
- Errors: never `try?` swallow in stores; map to `DockyardError` and surface via `AppModel.toast(_:)`.
- Upstream models never leak past `Backend/`. Convert to `Models/*` structs.
- Upstream version pin lives in exactly one place: `Packages/DockyardCore/Package.swift`. Bumping it is its own task.
