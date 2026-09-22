# T13 — Build sheet via `container build`

**Milestone:** M3 · **Depends on:** T10 · **Status:** todo

## Goal
Build an image from a Dockerfile/Containerfile with streamed output and cancellation. v1 runs the CLI
(the build pipeline is CLI-only upstream); the sheet/store API is designed so T-future can swap in the
`ContainerBuild` gRPC pipeline without UI changes.

## Upstream references
- `Sources/ContainerCommands/BuildCommand.swift` — flags: `-t/--tag`, `-f/--file`, `--platform`, `--build-arg`, `--no-cache`, `--progress`, `--cpus`, `--memory`, `--target`, `--label`, `-o/--output`; builder auto-start behaviour (`BuilderStart.start` + wait loop).
- `Sources/ContainerCommands/Builder/BuilderStart.swift`, `BuilderStatus.swift`, `BuilderStop.swift`.

## Files
- `Models/BuildSpec.swift` — `contextURL, dockerfile (relative path), tag, platform?, buildArgs: [String:String], noCache, target?, labels`. `func cliArguments() -> [String]` (unit-tested).
- `Backend/CLIRunner.swift` — `build(_ spec: BuildSpec) -> AsyncThrowingStream<CLIEvent, Error>`; pass `--progress plain` so output is line-based; `cwd = contextURL`.
- `Stores/BuildStore.swift` — `jobs: [BuildJob]` (spec, lines, state .running/.succeeded/.failed(code), task); `start(spec:)`, `cancel(_:)`; on success `imageStore.refresh()`.
- `Dockyard/Images/BuildSheet.swift` — folder chooser (NSOpenPanel, `canChooseDirectories`) + drop target; Dockerfile picker auto-selects `Dockerfile` then `Containerfile` if present; tag (required, validated `name[:tag]`); platform; build-args KV editor; no-cache toggle; target field.
- `Dockyard/Images/BuildJobView.swift` — reuses `LogTextView` for output, Cancel/Close, elapsed time; jobs listed in Images sidebar section "Builds".
- `Tests/DockyardCoreTests/BuildSpecTests.swift`.

## Acceptance
- [ ] Build `FROM alpine:3.20\nRUN echo hi > /hi` tagged `dockyard-test:1` → output streams → image appears; `container image list` agrees.
- [ ] First build with builder stopped: output shows builder starting; build still succeeds.
- [ ] Failing Dockerfile (`RUN false`) → job `.failed(1)`, error lines visible.
- [ ] Cancel mid-build → process terminated (`ps` shows no `container build`), job `.failed(cancelled)`.
- [ ] Unit tests green.

## Notes
